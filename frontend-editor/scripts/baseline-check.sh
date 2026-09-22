#!/usr/bin/env bash
#
# baseline-check.sh — MD Live Editor 可复现基线检查
#
# 一条命令覆盖：环境预检 / 依赖完整性 / 未知环境变量 / 端口占用 /
#               dev 启动与核心渲染入口 / 生产构建 / 产物完整性 / preview 回归 /
#               服务清理与业务源码零改动校验。
#
# 检查期间启动的 vite dev / preview 运行在独立进程组中，结束（含失败、Ctrl-C）
# 一律整组回收，并确认端口真正关闭；业务源码（src/、index.html、配置文件）
# 前后做摘要比对，任何被检查过程改写都判失败。
#
# 用法:
#   npm run check:baseline [-- --dev-port 5173] [--preview-port 4173] [--no-color]
#
# 退出码（每个失败原因对应明确结果）:
#   0  全部通过
#   10 运行环境不满足（node/npm 版本或可执行文件缺失）
#   11 依赖缺失或不完整（node_modules / 关键包 / 平台原生包）
#   12 存在未在 .env.example 登记的未知环境变量
#   13 端口被占用（dev 或 preview 端口）
#   14 dev server 启动失败或核心渲染入口冒烟未通过
#   15 生产构建失败（vite build）
#   16 构建产物缺失或内容不完整（dist）
#   17 preview 回归冒烟未通过
#   18 检查过程改写了受保护的业务源码
#
set -u

# ---------- 参数 ----------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_NODE_MAJOR=20
DEV_PORT=5173
PREVIEW_PORT=4173
USE_COLOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dev-port)      DEV_PORT="$2"; shift 2 ;;
    --preview-port)  PREVIEW_PORT="$2"; shift 2 ;;
    --no-color)      USE_COLOR=0; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数: $1（见 --help）" >&2; exit 2 ;;
  esac
done

for p in "$DEV_PORT" "$PREVIEW_PORT"; do
  case "$p" in ''|*[!0-9]*) echo "端口必须是数字，收到: $p" >&2; exit 2 ;; esac
  if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then echo "端口越界: $p" >&2; exit 2; fi
done

# ---------- 输出 ----------
if [ "$USE_COLOR" -eq 1 ] && [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_DIM=''; C_RST=''
fi

STEP=0
TOTAL=9
step()  { STEP=$((STEP+1)); printf '\n%s[%d/%d] %s%s\n' "$C_CYAN" "$STEP" "$TOTAL" "$1" "$C_RST"; }
ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RST" "$1"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RST" "$1"; }
fail()  { printf '  %s✗ %s%s\n' "$C_RED" "$1" "$C_RST" >&2; }
info()  { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }

die() {
  local code="$1"; shift
  fail "$*"
  fail "基线检查未通过（退出码 $code）"
  exit "$code"
}

# ---------- 临时目录与进程清理 ----------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/md-baseline.XXXXXX")"
DEV_PGID_FILE="$TMP_DIR/dev.pgid"; PREV_PGID_FILE="$TMP_DIR/preview.pgid"
BUILD_PGID_FILE="$TMP_DIR/build.pgid"
KILLED_SERVICES=()

kill_group() {
  local pgid_file="$1" label="$2"
  if [ -s "$pgid_file" ]; then
    local pgid; pgid="$(cat "$pgid_file")"
    if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
      kill -TERM -- "-$pgid" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$pgid" 2>/dev/null || true
      KILLED_SERVICES+=("$label(pgid $pgid)")
    fi
    : > "$pgid_file"
  fi
}

cleanup() {
  kill_group "$DEV_PGID_FILE" "vite-dev"
  kill_group "$PREV_PGID_FILE" "vite-preview"
  kill_group "$BUILD_PGID_FILE" "vite-build"
  if [ ${#KILLED_SERVICES[@]} -gt 0 ]; then
    printf '  %s已回收服务进程组: %s%s\n' "$C_DIM" "${KILLED_SERVICES[*]}" "$C_RST"
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
interrupted() {
  trap - INT TERM
  printf '\n  %s收到中断信号，正在回收服务并退出...%s\n' "$C_YELLOW" "$C_RST" >&2
  exit 130
}
trap interrupted INT TERM

cd "$ROOT_DIR" || { echo "无法进入 $ROOT_DIR" >&2; exit 2; }

# 端口状态：node 直连，输出 free / in-use / unknown
port_state() {
  node - "$1" <<'NODE'
const net = require('net')
const port = Number(process.argv[2])
const srv = net.createServer()
srv.once('error', (err) => {
  console.log(err.code === 'EADDRINUSE' ? 'in-use' : 'unknown')
  process.exit(0)
})
srv.listen(port, '0.0.0.0', () => srv.close(() => { console.log('free'); process.exit(0) }))
setTimeout(() => { console.log('unknown'); process.exit(0) }, 3000).unref()
NODE
}

assert_port_free() {
  local port="$1" who="$2"
  local state; state="$(port_state "$port")"
  case "$state" in
    free) ok "端口 $port 空闲，可用于 $who" ;;
    in-use)
      fail "端口 $port 已被占用（$who 需要它），基线拒绝在未知进程上做检查"
      if command -v ss >/dev/null 2>&1; then
        info "占用方参考: ss -ltnp 'sport = :$port'"
      else
        info "可执行 lsof -iTCP:$port -sTCP:LISTEN 或 fuser ${port}/tcp 查看占用方"
      fi
      info "也可用 --dev-port / --preview-port 指定其他端口重跑"
      return 13
      ;;
    *)
      fail "无法确定端口 $port 的状态（绑定探测返回 $state）"
      return 13 ;;
  esac
}

# 在独立进程组启动服务；包装脚本先落盘 pgid 再 exec 服务
start_server_group() {
  local label="$1" log_file="$2" pgid_file="$3"; shift 3
  local wrapper="$TMP_DIR/${label}.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo $$ > %q\n' "$pgid_file"
    printf 'exec "$@"\n'
  } > "$wrapper"
  chmod +x "$wrapper"
  setsid "$wrapper" "$@" > "$log_file" 2>&1 &
  local i
  for i in $(seq 1 50); do
    [ -s "$pgid_file" ] && return 0
    sleep 0.1
  done
  return 1
}

# 轮询 HTTP 直到返回 200
wait_http() {
  local url="$1" timeout_s="$2" log_file="$3" i code
  for i in $(seq 1 "$((timeout_s * 10))"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
    [ "$code" = "200" ] && return 0
    sleep 1
  done
  return 1
}

dump_log_tail() {
  local log_file="$1"
  if [ -s "$log_file" ]; then
    printf '  %s--- %s 末尾日志 ---%s\n' "$C_DIM" "$log_file" "$C_RST" >&2
    tail -n 40 "$log_file" | sed 's/^/    /' >&2
    printf '  %s------------------------%s\n' "$C_DIM" "$C_RST" >&2
  fi
}

printf '%sMD Live Editor · 可复现基线检查%s\n' "$C_BOLD" "$C_RST"
printf '  项目目录 : %s\n' "$ROOT_DIR"
printf '  dev 端口 : %s    preview 端口 : %s\n' "$DEV_PORT" "$PREVIEW_PORT"

# ========== 1/9 运行环境预检 ==========
step "运行环境预检（node / npm / 平台）"

[ -f .nvmrc ] && EXPECTED_NODE_MAJOR="$(sed 's/[^0-9].*//;s/[^0-9]//g' .nvmrc | head -c 2)"
[ -n "$EXPECTED_NODE_MAJOR" ] || EXPECTED_NODE_MAJOR=20

if ! command -v node >/dev/null 2>&1; then
  die 10 "未找到 node（要求 Node.js ${EXPECTED_NODE_MAJOR}.x，见 .nvmrc）；请安装后重跑，例如 nvm install"
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" != "$EXPECTED_NODE_MAJOR" ] && ! { [ "$NODE_MAJOR" -gt "$EXPECTED_NODE_MAJOR" ] 2>/dev/null; }; then
  die 10 "Node.js 主版本为 ${NODE_MAJOR}，基线要求 ${EXPECTED_NODE_MAJOR}.x（Dockerfile 同为 node:20-alpine）；请 nvm use 后重跑"
fi
if [ "$NODE_MAJOR" != "$EXPECTED_NODE_MAJOR" ]; then
  warn "Node.js 主版本为 ${NODE_MAJOR}，基线登记为 ${EXPECTED_NODE_MAJOR}.x（更高版本未验证，建议切换）"
else
  ok "node $(node -v)（主版本 ${NODE_MAJOR} 与 .nvmrc / Dockerfile 一致）"
fi

command -v npm >/dev/null 2>&1 || die 10 "未找到 npm，请随 Node.js ${EXPECTED_NODE_MAJOR}.x 一并安装"
ok "npm $(npm -v)"
ok "平台 $(uname -s)-$(uname -m)，curl $(curl --version | head -1 | awk '{print $2}')"

# ========== 2/9 依赖完整性 ==========
step "依赖完整性（node_modules 与关键包）"

[ -f package.json ] || die 11 "缺少 package.json（当前目录: $ROOT_DIR）"

if [ ! -d node_modules ]; then
  die 11 "node_modules 不存在；请先执行 npm ci（或 npm install）再重跑基线"
fi
ok "node_modules 已存在（基线不自动改写依赖锁文件，如确需安装请人工执行 npm ci）"

if ! npm ls --depth=0 --omit=dev >/dev/null 2>"$TMP_DIR/npm-ls.log"; then
  fail "npm ls 报告运行时依赖树不完整："
  sed 's/^/    /' "$TMP_DIR/npm-ls.log" | tail -n 20 >&2
  die 11 "运行时依赖缺失或版本冲突；请删除 node_modules 后执行 npm ci 修复"
fi
ok "npm ls 运行时依赖树完整"

# 关键包必须可被 require；rollup 原生包是跨平台拷贝 node_modules 时最常见的缺失
MISSING_PKGS=""
for pkg in vue pinia markdown-it @codemirror/view @codemirror/state rollup; do
  if ! node -e "require.resolve('$pkg')" >/dev/null 2>&1; then
    MISSING_PKGS="$MISSING_PKGS $pkg"
  fi
done
[ -z "$MISSING_PKGS" ] || die 11 "关键依赖无法解析：${MISSING_PKGS# }；请执行 npm ci"
ok "关键包可解析：vue / pinia / markdown-it / @codemirror/* / rollup"

if ! node -e "require('rollup')" >/dev/null 2>&1; then
  arch="$(uname -m)"; case "$arch" in aarch64|arm64) arch="arm64-gnu" ;; x86_64|amd64) arch="x64-gnu" ;; esac
  fail "rollup 包存在但其平台原生绑定无法加载（@rollup/rollup-$(uname -s | tr '[:upper:]' '[:lower:]')-${arch} 缺失或架构不符）"
  die 11 "当前 node_modules 与平台 $(uname -m) 不匹配（常见于跨机器拷贝）；请删除 node_modules 后 npm ci"
fi
ok "rollup 平台原生绑定可加载（构建前置条件满足）"

[ -x node_modules/.bin/vite ] || die 11 "node_modules/.bin/vite 不存在，devDependencies 未安装完整；请执行 npm ci"
ok "vite 可执行文件就位"

# ========== 3/9 环境变量登记 ==========
step "环境变量基线（.env.example 登记制）"

[ -f .env.example ] || die 12 "缺少 .env.example：所有环境变量必须先在此登记"

ENV_KEYS_SCRIPT="$TMP_DIR/env-keys.js"
cat > "$ENV_KEYS_SCRIPT" <<'NODE'
// 输出 env 文件中的顶层 KEY（忽略注释行与行内注释）
const fs = require('fs')
const file = process.argv[2]
if (!fs.existsSync(file)) process.exit(0)
const out = new Set()
for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  const line = raw.trim()
  if (!line || line.startsWith('#')) continue
  const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=/)
  if (m) out.add(m[1])
}
for (const k of [...out].sort()) console.log(k)
NODE

mapfile -t DECLARED < <(node "$ENV_KEYS_SCRIPT" .env.example)
ok ".env.example 登记变量: ${DECLARED[*]:-（无，应用当前不依赖任何环境变量）}"

UNKNOWN_VARS=""
ENV_FILES=(.env)
for f in .env.local .env.development.local .env.production.local; do
  [ -f "$f" ] && ENV_FILES+=("$f")
done
for f in "${ENV_FILES[@]}"; do
  [ -f "$f" ] || continue
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    found=0
    for d in "${DECLARED[@]:-}"; do [ "$key" = "$d" ] && found=1 && break; done
    if [ "$found" -eq 0 ]; then
      UNKNOWN_VARS="$UNKNOWN_VARS $f:$key"
    fi
  done < <(node "$ENV_KEYS_SCRIPT" "$f")
done

if [ -n "$UNKNOWN_VARS" ]; then
  fail "发现未登记的未知环境变量（文件:变量名）：${UNKNOWN_VARS# }"
  die 12 "请先在 .env.example 登记（Vite 仅暴露 VITE_ 前缀变量），或从本地 env 文件移除后重跑"
fi
if [ ${#ENV_FILES[@]} -eq 1 ] && [ ! -f .env ]; then
  ok "无 .env / .env.local 等本地环境文件，使用内置默认配置"
else
  ok "本地环境文件（${ENV_FILES[*]}）中的变量均已在 .env.example 登记"
fi

# ========== 4/9 业务源码保护快照 ==========
step "业务源码保护（检查前后摘要比对）"

GUARD_LIST=(
  index.html vite.config.js package.json package-lock.json
  src/main.js src/App.vue
  src/components/EditorPane.vue src/components/Toolbar.vue src/components/StatusBar.vue
  src/stores/editor.js
  src/editor/index.js src/editor/setup.js src/editor/theme.js
  src/editor/decoration-plugin.js src/editor/markdown-parser.js
  src/styles/global.scss src/styles/editor-theme.scss src/styles/_variables.scss
)
SNAP_BEFORE="$TMP_DIR/src.before.sha"
: > "$SNAP_BEFORE"
for f in "${GUARD_LIST[@]}"; do
  [ -f "$f" ] || die 18 "受保护源码缺失: $f（基线自身不应导致此问题，请检查工作区）"
  sha256sum "$f" >> "$SNAP_BEFORE"
done
ok "已对 ${#GUARD_LIST[@]} 个业务源码/配置文件建立检查前摘要（dist、node_modules 不在保护范围）"

# ========== 5/9 端口占用预检 ==========
step "端口占用预检"

assert_port_free "$DEV_PORT" "vite dev" || exit 13
assert_port_free "$PREVIEW_PORT" "vite preview" || exit 13

# ========== 6/9 dev 启动 + 核心渲染入口冒烟 ==========
step "dev server 启动与核心渲染入口冒烟"

DEV_LOG="$TMP_DIR/dev.log"
if ! start_server_group "dev" "$DEV_LOG" "$DEV_PGID_FILE" \
      node_modules/.bin/vite --port "$DEV_PORT" --strictPort --host 127.0.0.1; then
  dump_log_tail "$DEV_LOG"
  die 14 "vite dev 未能启动（进程组 pgid 文件未落盘）"
fi

if ! wait_http "http://127.0.0.1:$DEV_PORT/" 30 "$DEV_LOG"; then
  dump_log_tail "$DEV_LOG"
  die 14 "vite dev 在 30s 内未于 http://127.0.0.1:$DEV_PORT/ 返回 200"
fi
ok "dev server 已启动: http://127.0.0.1:$DEV_PORT/（--strictPort，端口即基线值）"

smoke_dev() {
  local path="$1" pattern="$2" desc="$3"
  local body="$TMP_DIR/smoke.$$"
  if ! curl -sf --max-time 10 "http://127.0.0.1:$DEV_PORT$path" -o "$body"; then
    fail "GET $path 请求失败（$desc）"
    return 1
  fi
  if ! grep -Eq "$pattern" "$body"; then
    fail "$desc：$path 响应未匹配 /$pattern/"
    head -c 400 "$body" | sed 's/^/    /' >&2
    return 1
  fi
  rm -f "$body"
  ok "$desc ← $path"
}

smoke_dev "/" '<div id="app"></div>' \
  'HTML 外壳包含 #app 挂载点' || { dump_log_tail "$DEV_LOG"; die 14 "核心渲染入口冒烟失败"; }
smoke_dev "/src/main.js" 'createApp|createPinia' \
  '应用入口 main.js 经 Vite 转译后含 createApp/createPinia' || { dump_log_tail "$DEV_LOG"; die 14 "核心渲染入口冒烟失败"; }
smoke_dev "/src/App.vue" 'Toolbar|EditorPane|StatusBar' \
  '根组件 App.vue 经 SFC 编译，含三大渲染区块' || { dump_log_tail "$DEV_LOG"; die 14 "核心渲染入口冒烟失败"; }
smoke_dev "/src/components/EditorPane.vue" 'createEditor|cm-editor|editor' \
  '核心渲染组件 EditorPane.vue（CodeMirror 挂载入口）编译通过' || { dump_log_tail "$DEV_LOG"; die 14 "核心渲染入口冒烟失败"; }
smoke_dev "/src/styles/global.scss" 'data-vite-dev-id|css' \
  '全局样式 SCSS 经 Vite 管道编译成功' || { dump_log_tail "$DEV_LOG"; die 14 "核心渲染入口冒烟失败"; }

if grep -Eiq 'failed to|internal server error|Pre-transform error' "$DEV_LOG"; then
  dump_log_tail "$DEV_LOG"
  die 14 "dev server 日志中出现错误标记（见上）"
fi
ok "dev 日志无错误标记"

# 立即回收 dev，构建阶段不允许残留服务
kill_group "$DEV_PGID_FILE" "vite-dev"
state_after="$(port_state "$DEV_PORT")"
[ "$state_after" = "free" ] || die 14 "dev 已停止但端口 $DEV_PORT 仍为 $state_after，基线中止以免残留服务"
ok "dev server 已回收，端口 $DEV_PORT 确认关闭"

# ========== 7/9 生产构建 ==========
step "生产构建（vite build → dist）"

BUILD_LOG="$TMP_DIR/build.log"
# 构建也跑在独立进程组，中断时由 cleanup 整组回收（含 rollup/esbuild 子进程）
BUILD_WRAPPER="$TMP_DIR/build.sh"
printf '#!/usr/bin/env bash\necho $$ > %q\nexec "$@"\n' "$BUILD_PGID_FILE" > "$BUILD_WRAPPER"
chmod +x "$BUILD_WRAPPER"
BUILD_RC=0
setsid "$BUILD_WRAPPER" npm run build > "$BUILD_LOG" 2>&1 &
BUILD_PID=$!
# wait 可能被到达的信号中断（返回 129/130）；只有后台作业真正结束才停止等待。
# 注意：必须在独立语句里先取 $?，不能写成 `if wait ...`——条件求值会把退出码重置为 0。
# 收到 SIGINT/TERM 时 interrupted trap 会 exit → EXIT trap 负责回收 build 进程组。
while :; do
  wait "$BUILD_PID"
  BUILD_RC=$?
  kill -0 "$BUILD_PID" 2>/dev/null || break
done
: > "$BUILD_PGID_FILE"
if [ "$BUILD_RC" -ne 0 ]; then
  fail "npm run build 退出码 $BUILD_RC"
  dump_log_tail "$BUILD_LOG"
  die 15 "生产构建失败（完整日志: $BUILD_LOG）"
fi
ok "vite build 成功（末行：$(grep -E 'built in' "$BUILD_LOG" | tail -1 | sed 's/^[[:space:]]*//')）"

# ========== 8/9 产物完整性 ==========
step "构建产物完整性（dist 结构与核心标记）"

ARTIFACT_OUT="$TMP_DIR/artifact.json"
if ! node - "$ARTIFACT_OUT" <<'NODE'
const fs = require('fs')
const path = require('path')
const dist = path.join(process.cwd(), 'dist')
const fail = (m) => { console.error('产物校验失败: ' + m); process.exit(1) }
if (!fs.existsSync(dist)) fail('dist/ 目录不存在')
const idx = path.join(dist, 'index.html')
if (!fs.existsSync(idx)) fail('dist/index.html 缺失')
const html = fs.readFileSync(idx, 'utf8')
const assets = [...html.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g)].map(m => m[1])
if (!assets.length) fail('index.html 未引用任何 /assets/* 构建资源')
for (const a of assets) {
  if (!fs.existsSync(path.join(dist, a))) fail('index.html 引用的资源不存在: ' + a)
}
const jsAssets = assets.filter(a => a.endsWith('.js'))
if (!jsAssets.length) fail('index.html 未引用 JS 入口 chunk')
const allJs = fs.readdirSync(path.join(dist, 'assets')).filter(f => f.endsWith('.js'))
const bundles = allJs.map(f => fs.readFileSync(path.join(dist, 'assets', f), 'utf8'))
const need = [
  ['Vue 运行时 createApp', /createApp/],
  ['Pinia store', /pinia|defineStore/],
  ['CodeMirror 编辑器视图（核心渲染）', /cm-editor|EditorView/],
  ['Markdown 装饰插件（即时渲染）', /Decoration|ViewPlugin|markdownDecorationPlugin/],
]
const missing = need.filter(([, re]) => !re.test(bundles.join('\n')))
if (missing.length) fail('JS chunk 缺少核心标记: ' + missing.map(m => m[0]).join('、'))
const css = fs.readdirSync(path.join(dist, 'assets')).filter(f => f.endsWith('.css'))
if (!css.length) fail('dist/assets 下没有任何 CSS 文件')
if (!/<title>.*Mira.*<\/title>/i.test(html)) fail('index.html 缺少应用标题 Mira')
fs.writeFileSync(process.argv[2], JSON.stringify({ assets, jsAssets, css, chunks: allJs.length }, null, 2))
NODE
then
  die 16 "构建产物不完整，见上方明细"
fi
ok "dist/index.html 存在且引用的 $(node -e "console.log(require('$ARTIFACT_OUT').assets.length)") 个资源全部落盘"
ok "JS chunk 含核心渲染标记：Vue createApp / Pinia / CodeMirror EditorView / Decoration 插件"
ok "CSS 产物存在（$(node -e "console.log(require('$ARTIFACT_OUT').css.join(', '))")）"
ok "产物 chunk 数: $(node -e "console.log(require('$ARTIFACT_OUT').chunks)")"

# ========== 9/9 preview 回归 ==========
step "preview 生产产物回归冒烟"

PREV_LOG="$TMP_DIR/preview.log"
if ! start_server_group "preview" "$PREV_LOG" "$PREV_PGID_FILE" \
      node_modules/.bin/vite preview --port "$PREVIEW_PORT" --strictPort --host 127.0.0.1; then
  dump_log_tail "$PREV_LOG"
  die 17 "vite preview 未能启动（进程组 pgid 文件未落盘）"
fi

if ! wait_http "http://127.0.0.1:$PREVIEW_PORT/" 20 "$PREV_LOG"; then
  dump_log_tail "$PREV_LOG"
  die 17 "vite preview 在 20s 内未于 http://127.0.0.1:$PREVIEW_PORT/ 返回 200"
fi
ok "preview server 已启动: http://127.0.0.1:$PREVIEW_PORT/"

preview_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PREVIEW_PORT/")"
[ "$preview_code" = "200" ] || die 17 "preview 根路径返回 $preview_code"
ok "GET / → 200"

ENTRY_JS="$(node -e "console.log(require('$ARTIFACT_OUT').jsAssets[0])")"
asset_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PREVIEW_PORT$ENTRY_JS")"
[ "$asset_code" = "200" ] || die 17 "入口资源 $ENTRY_JS 返回 $asset_code（期望 200）"
ok "入口 JS 资源可访问 → 200（$ENTRY_JS）"

SPA_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PREVIEW_PORT/some/spa/route")"
[ "$SPA_CODE" = "200" ] || die 17 "SPA 回退路由 /some/spa/route 返回 $SPA_CODE（期望 index.html 200）"
ok "深链接 SPA 回退正常: /some/spa/route → 200"

if grep -Eiq 'failed to|internal server error' "$PREV_LOG"; then
  dump_log_tail "$PREV_LOG"
  die 17 "preview 日志中出现错误标记（见上）"
fi
ok "preview 日志无错误标记"

kill_group "$PREV_PGID_FILE" "vite-preview"
state_after="$(port_state "$PREVIEW_PORT")"
[ "$state_after" = "free" ] || die 17 "preview 已停止但端口 $PREVIEW_PORT 仍为 $state_after，基线中止以免残留服务"
ok "preview server 已回收，端口 $PREVIEW_PORT 确认关闭"

# ========== 源码零改动终检 ==========
printf '\n%s[终检] 业务源码零改动%s\n' "$C_CYAN" "$C_RST"

SNAP_AFTER="$TMP_DIR/src.after.sha"
: > "$SNAP_AFTER"
for f in "${GUARD_LIST[@]}"; do
  if [ ! -f "$f" ]; then die 18 "受保护源码在检查过程中消失: $f"; fi
  sha256sum "$f" >> "$SNAP_AFTER"
done
if ! diff -u "$SNAP_BEFORE" "$SNAP_AFTER" > "$TMP_DIR/snap.diff"; then
  fail "以下业务源码/配置在检查过程中被改写："
  grep -E '^[+-][^+-]' "$TMP_DIR/snap.diff" | sed 's/^/    /' >&2
  die 18 "基线检查不允许改写业务源码（构建产物 dist/、依赖 node_modules/ 不受此限）"
fi
ok "全部 ${#GUARD_LIST[@]} 个受保护文件摘要与检查前一致"

# ---------- 汇总 ----------
printf '\n%s基线结果%s  ' "$C_BOLD" "$C_RST"
printf '%s全部通过%s\n' "$C_GREEN" "$C_RST"
printf '  环境   node %s / npm %s / %s\n' "$(node -v)" "$(npm -v)" "$(uname -m)"
printf '  依赖   node_modules 完整，rollup 原生绑定匹配当前平台\n'
printf '  变量   %s\n' "${DECLARED[*]:-无登记变量，本地也无未知变量}"
printf '  端口   dev %s / preview %s，检查后均已关闭\n' "$DEV_PORT" "$PREVIEW_PORT"
printf '  冒烟   dev 5 项（外壳+入口+根组件+编辑器组件+SCSS），preview 3 项（根+资源+SPA回退）\n'
printf '  构建   vite build 成功，dist 产物结构与核心标记齐全\n'
printf '  源码   业务源码零改动；临时文件 %s 已清理\n' "$TMP_DIR"
exit 0
