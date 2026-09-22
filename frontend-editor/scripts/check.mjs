#!/usr/bin/env node
/**
 * 可复现基线回归检查
 *
 * 覆盖阶段（按依赖顺序执行）：
 *   env       环境基线：Node/npm 版本、.env 与进程环境中的未知变量、端口变量合法性
 *   deps      依赖完整性：node_modules、声明依赖、平台原生依赖（rollup/esbuild）
 *   ports     端口可用性：dev / preview 端口未被占用
 *   entry     核心渲染入口：index.html/#app、main.js 挂载、editor 入口、Markdown 解析自检
 *   build     生产构建：npm run build 必须成功
 *   artifacts 构建产物：dist/index.html 与入口 JS 产物存在且非空
 *   serve     启动冒烟：dev 服务器与 preview 服务器可启动并返回核心渲染入口
 *
 * 保证：只读取业务源码，不做任何改写；启动的服务在退出前无条件回收，不残留进程。
 *
 * 用法：node scripts/check.mjs [--only=env,deps] [--skip=serve] [--help]
 * 退出码：0 全部通过；1 存在失败阶段。
 */
import { createServer } from 'node:net'
import { get } from 'node:http'
import { spawn } from 'node:child_process'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const VITE_BIN = join(ROOT, 'node_modules', 'vite', 'bin', 'vite.js')

// 与 vite.config.js 一致的环境默认值基线
const DEFAULTS = { host: '0.0.0.0', devPort: 5173, previewPort: 4173 }
const ENV_EXAMPLE = join(ROOT, '.env.example')
const ENV_FILE = join(ROOT, '.env')

// ---------------------------------------------------------------- 工具

function parseEnvFile(path) {
  const vars = {}
  if (!existsSync(path)) return vars
  for (const raw of readFileSync(path, 'utf8').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/)
    if (m) vars[m[1]] = m[2].trim().replace(/^["']|["']$/g, '')
  }
  return vars
}

/** 与 vite 配置相同的生效配置解析：默认值 < .env 文件 < 进程环境 */
function resolveConfig() {
  const fileVars = parseEnvFile(ENV_FILE)
  const pick = (key) => process.env[key] ?? fileVars[key]
  return {
    host: pick('VITE_DEV_HOST') || DEFAULTS.host,
    devPort: Number(pick('VITE_DEV_PORT')) || DEFAULTS.devPort,
    previewPort: Number(pick('VITE_PREVIEW_PORT')) || DEFAULTS.previewPort
  }
}

function isPortFree(port, host = '0.0.0.0') {
  return new Promise((resolvePromise) => {
    const srv = createServer()
    srv.once('error', () => resolvePromise(false))
    srv.once('listening', () => srv.close(() => resolvePromise(true)))
    srv.listen(port, host)
  })
}

async function waitPortFree(port, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await isPortFree(port)) return true
    await new Promise((r) => setTimeout(r, 200))
  }
  return false
}

function httpGet(port, path) {
  return new Promise((resolvePromise, reject) => {
    const req = get({ host: '127.0.0.1', port, path, timeout: 5000 }, (res) => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { body += chunk })
      res.on('end', () => resolvePromise({ status: res.statusCode, body }))
    })
    req.on('timeout', () => req.destroy(new Error('请求超时')))
    req.on('error', reject)
  })
}

// ---------------------------------------------------------------- 子进程管理

const children = new Set()

function killChild(child) {
  if (!child || child.exitCode !== null) return
  // detached 启动 => 子进程为进程组组长，负 pid 整组回收，避免残留 esbuild 等子孙进程
  for (const signal of ['SIGTERM', 'SIGKILL']) {
    try { process.kill(-child.pid, signal) } catch { /* 已退出 */ }
    try { process.kill(child.pid, signal) } catch { /* 已退出 */ }
  }
}

function cleanupChildren() {
  for (const child of children) killChild(child)
  children.clear()
}

process.on('SIGINT', () => { cleanupChildren(); process.exit(130) })
process.on('SIGTERM', () => { cleanupChildren(); process.exit(143) })
process.on('uncaughtException', (err) => {
  cleanupChildren()
  console.error(`\n[FAIL] 检查脚本自身异常: ${err.message}`)
  process.exit(1)
})

/** 启动服务并等待其可响应；返回 { child, logs }，失败时抛出带日志的错误 */
async function startServer(name, args, port, readyPath = '/', timeoutMs = 30000) {
  const child = spawn(process.execPath, [VITE_BIN, ...args], {
    cwd: ROOT,
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: process.env
  })
  children.add(child)
  let logs = ''
  child.stdout.on('data', (d) => { logs += d })
  child.stderr.on('data', (d) => { logs += d })

  const exited = new Promise((r) => child.once('exit', (code) => r(code)))
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const earlyExit = await Promise.race([exited.then((c) => ({ exited: c })), new Promise((r) => setTimeout(() => r(null), 300))])
    if (earlyExit?.exited != null) {
      throw new Error(`${name} 启动后即退出（code=${earlyExit.exited}）。端口可能被占用或配置非法。\n${logs.trim().slice(-600)}`)
    }
    try {
      const res = await httpGet(port, readyPath)
      if (res.status === 200) return { child, logs: () => logs, firstResponse: res }
    } catch { /* 尚未就绪，继续等待 */ }
  }
  throw new Error(`${name} 在 ${timeoutMs / 1000}s 内未就绪。\n${logs.trim().slice(-600)}`)
}

// ---------------------------------------------------------------- 结果记录

const results = []
function record(stage, status, message, details = []) {
  results.push({ stage, status, message })
  const icon = { pass: 'PASS', fail: 'FAIL', skip: 'SKIP' }[status]
  console.log(`[${icon}] ${stage}: ${message}`)
  for (const d of details) console.log(`       ${d}`)
}
const pass = (stage, message, details) => record(stage, 'pass', message, details)
const fail = (stage, message, details) => record(stage, 'fail', message, details)
const skip = (stage, reason) => record(stage, 'skip', `跳过（${reason}）`)
const ran = (stage) => results.some((r) => r.stage === stage)

// ---------------------------------------------------------------- 阶段：env

function checkEnv() {
  const problems = []
  const details = []

  const nodeMajor = Number(process.versions.node.split('.')[0])
  if (nodeMajor < 18) {
    problems.push(`Node 版本过低: ${process.version}（package.json engines 要求 >=18）`)
  } else {
    details.push(`Node ${process.version}`)
  }

  const agent = process.env.npm_config_user_agent || ''
  const npmVer = agent.match(/npm\/(\d+)/)?.[1]
  if (npmVer && Number(npmVer) < 9) problems.push(`npm 版本过低: ${npmVer}（要求 >=9）`)

  if (!existsSync(ENV_EXAMPLE)) {
    problems.push('缺少环境基线文件 .env.example')
    return fail('env', problems.join('；'))
  }
  const known = new Set(Object.keys(parseEnvFile(ENV_EXAMPLE)))

  // 未知变量：.env 文件与进程环境中出现未在 .env.example 声明的 VITE_* 变量
  const fileVars = parseEnvFile(ENV_FILE)
  const unknownInFile = Object.keys(fileVars).filter((k) => !known.has(k))
  if (unknownInFile.length) {
    problems.push(`.env 中存在未知变量: ${unknownInFile.join(', ')}（未在 .env.example 声明，不会生效）`)
  }
  const unknownInEnv = Object.keys(process.env).filter((k) => k.startsWith('VITE_') && !known.has(k))
  if (unknownInEnv.length) {
    problems.push(`进程环境中存在未知变量: ${unknownInEnv.join(', ')}（未在 .env.example 声明）`)
  }

  const cfg = resolveConfig()
  for (const [label, port] of [['VITE_DEV_PORT', cfg.devPort], ['VITE_PREVIEW_PORT', cfg.previewPort]]) {
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      problems.push(`${label} 非法: ${port}（应为 1-65535 的整数）`)
    }
  }
  if (!cfg.host) problems.push('VITE_DEV_HOST 不能为空')

  if (problems.length) return fail('env', problems.join('；'))
  pass('env', `环境基线正常（dev=${cfg.host}:${cfg.devPort}, preview=${cfg.host}:${cfg.previewPort}）`, details)
}

// ---------------------------------------------------------------- 阶段：deps

function checkDeps() {
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))
  const declared = [...Object.keys(pkg.dependencies || {}), ...Object.keys(pkg.devDependencies || {})]

  if (!existsSync(join(ROOT, 'node_modules'))) {
    return fail('deps', '缺少依赖: node_modules 不存在，请先运行 npm install（或 npm ci）')
  }

  const missing = declared.filter((name) => !existsSync(join(ROOT, 'node_modules', name, 'package.json')))
  if (missing.length) {
    return fail('deps', `缺少依赖: ${missing.join(', ')}（运行 npm install 修复）`)
  }

  // 平台原生依赖（npm 可选依赖缺陷的高发点，缺失会导致构建直接崩溃）
  const nativeCandidates = {
    linux: { x64: ['linux-x64-gnu', 'linux-x64-musl'], arm64: ['linux-arm64-gnu', 'linux-arm64-musl'], arm: ['linux-arm-gnueabihf', 'linux-arm-musleabihf'] },
    darwin: { x64: ['darwin-x64'], arm64: ['darwin-arm64'] },
    win32: { x64: ['win32-x64-msvc'], arm64: ['win32-arm64-msvc'], ia32: ['win32-ia32-msvc'] }
  }
  const rollupNames = nativeCandidates[process.platform]?.[process.arch] || []
  const nativeMissing = []
  if (rollupNames.length && !rollupNames.some((n) => existsSync(join(ROOT, 'node_modules', '@rollup', `rollup-${n}`)))) {
    nativeMissing.push(`@rollup/rollup-${rollupNames[0]}`)
  }
  const esbuildName = `${process.platform}-${process.arch}`
  if (!existsSync(join(ROOT, 'node_modules', '@esbuild', esbuildName))) {
    nativeMissing.push(`@esbuild/${esbuildName}`)
  }
  if (nativeMissing.length) {
    return fail('deps', `缺少平台原生依赖: ${nativeMissing.join(', ')}（npm 可选依赖缺陷，删除 node_modules 后运行 npm install 修复）`)
  }

  if (!existsSync(VITE_BIN)) {
    return fail('deps', '缺少依赖: vite 未安装（node_modules/vite/bin/vite.js 不存在）')
  }

  const warnings = []
  const innerLock = join(ROOT, 'node_modules', '.package-lock.json')
  const outerLock = join(ROOT, 'package-lock.json')
  if (existsSync(outerLock) && existsSync(innerLock) && statSync(outerLock).mtimeMs > statSync(innerLock).mtimeMs) {
    warnings.push('package-lock.json 比已安装依赖新，建议运行 npm ci 对齐')
  }
  pass('deps', `依赖完整（${declared.length} 个声明依赖均已安装）`, warnings)
}

// ---------------------------------------------------------------- 阶段：ports

async function checkPorts() {
  const cfg = resolveConfig()
  const busy = []
  if (!(await isPortFree(cfg.devPort, cfg.host))) busy.push(`${cfg.devPort}（dev）`)
  if (!(await isPortFree(cfg.previewPort, cfg.host))) busy.push(`${cfg.previewPort}（preview）`)
  if (busy.length) {
    return fail('ports', `端口被占用: ${busy.join(', ')}（释放端口或修改 .env 中的 VITE_DEV_PORT / VITE_PREVIEW_PORT）`)
  }
  pass('ports', `端口空闲（dev=${cfg.devPort}, preview=${cfg.previewPort}）`)
}

// ---------------------------------------------------------------- 阶段：entry

async function checkEntry() {
  const problems = []

  const indexHtml = join(ROOT, 'index.html')
  if (!existsSync(indexHtml)) problems.push('缺少 index.html')
  else {
    const html = readFileSync(indexHtml, 'utf8')
    if (!html.includes('id="app"')) problems.push('index.html 缺少 #app 挂载点')
    if (!html.includes('/src/main.js')) problems.push('index.html 未引用 /src/main.js 入口')
  }

  const mainJs = join(ROOT, 'src', 'main.js')
  if (!existsSync(mainJs)) problems.push('缺少 src/main.js')
  else {
    const src = readFileSync(mainJs, 'utf8')
    if (!/createApp/.test(src)) problems.push('src/main.js 未调用 createApp')
    if (!/mount\(\s*['"]#app['"]/.test(src)) problems.push("src/main.js 未挂载到 '#app'")
  }

  const editorIndex = join(ROOT, 'src', 'editor', 'index.js')
  const editorSetup = join(ROOT, 'src', 'editor', 'setup.js')
  if (!existsSync(editorIndex)) problems.push('缺少 src/editor/index.js（编辑器入口）')
  if (!existsSync(editorSetup)) problems.push('缺少 src/editor/setup.js（createEditor 定义）')
  else {
    const setup = readFileSync(editorSetup, 'utf8')
    if (!/export function createEditor/.test(setup)) problems.push('src/editor/setup.js 未导出 createEditor')
    if (!/defaultContent/.test(setup)) problems.push('src/editor/setup.js 缺少默认示例 defaultContent')
  }

  if (problems.length) return fail('entry', problems.join('；'))

  // 核心渲染逻辑自检：Markdown 区域解析是 Decoration 渲染的数据源，纯函数可在 Node 中直接验证
  try {
    const { parseMarkdownRegions, regionAtPos } = await import(join(ROOT, 'src', 'editor', 'markdown-parser.js'))
    const sample = '# Title\n\nSome **bold** and [a link](https://example.com).\n\n```js\ncode\n```\n'
    const regions = parseMarkdownRegions(sample)
    const byType = (t) => regions.find((r) => r.type === t)
    const asserts = [
      [byType('heading')?.meta?.level === 1, 'heading 区域（level=1）'],
      [byType('bold') && sample.slice(byType('bold').contentFrom, byType('bold').contentTo) === 'bold', 'bold 区域内容'],
      [byType('link')?.meta?.url === 'https://example.com', 'link 区域 URL'],
      [byType('code-block')?.meta?.language === 'js', 'code-block 区域语言'],
      [regionAtPos(regions, 2)?.type === 'heading', 'regionAtPos 光标定位']
    ]
    const failedAsserts = asserts.filter(([ok]) => !ok).map(([, name]) => name)
    if (regions.length === 0 || failedAsserts.length) {
      return fail('entry', `核心渲染入口自检失败: ${failedAsserts.join(', ') || '解析结果为空'}`)
    }
  } catch (err) {
    return fail('entry', `核心渲染入口自检异常: ${err.message}`)
  }

  pass('entry', '核心渲染入口完整（#app 挂载、createEditor、Markdown 解析自检通过）')
}

// ---------------------------------------------------------------- 阶段：build

async function checkBuild() {
  const child = spawn('npm', ['run', 'build'], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] })
  children.add(child)
  let logs = ''
  child.stdout.on('data', (d) => { logs += d })
  child.stderr.on('data', (d) => { logs += d })
  const code = await new Promise((r) => child.once('exit', r))
  children.delete(child)
  if (code !== 0) {
    return fail('build', `构建失败: npm run build 退出码 ${code}`, [logs.trim().slice(-800)])
  }
  pass('build', '构建成功（npm run build）')
}

// ---------------------------------------------------------------- 阶段：artifacts

function checkArtifacts() {
  const dist = join(ROOT, 'dist')
  const indexHtml = join(dist, 'index.html')
  if (!existsSync(indexHtml)) {
    return fail('artifacts', '产物缺失: dist/index.html 不存在（构建未完成或输出目录被清空）')
  }
  const html = readFileSync(indexHtml, 'utf8')
  if (!html.includes('id="app"')) {
    return fail('artifacts', '产物异常: dist/index.html 缺少 #app 挂载点')
  }
  const entrySrc = html.match(/<script[^>]+src="([^"]+\.js)"/)?.[1]
  if (!entrySrc) {
    return fail('artifacts', '产物缺失: dist/index.html 未引用入口 JS')
  }
  const entryFile = join(dist, entrySrc)
  if (!existsSync(entryFile) || statSync(entryFile).size === 0) {
    return fail('artifacts', `产物缺失: 入口 JS ${entrySrc} 不存在或为空`)
  }
  const jsAssets = existsSync(join(dist, 'assets'))
    ? readdirSync(join(dist, 'assets')).filter((f) => f.endsWith('.js') && statSync(join(dist, 'assets', f)).size > 0)
    : []
  if (!jsAssets.length) {
    return fail('artifacts', '产物缺失: dist/assets 下没有非空 JS 产物')
  }
  pass('artifacts', `产物完整（dist/index.html + ${jsAssets.length} 个 JS 产物，入口 ${entrySrc}）`)
}

// ---------------------------------------------------------------- 阶段：serve

async function checkServe() {
  const cfg = resolveConfig()
  const notes = []

  // preview：验证构建产物可被正式伺服
  const preview = await startServer('preview 服务器', ['preview'], cfg.previewPort)
  try {
    const home = preview.firstResponse
    if (!home.body.includes('id="app"')) throw new Error('preview / 响应缺少 #app 挂载点')
    const entrySrc = home.body.match(/<script[^>]+src="([^"]+\.js)"/)?.[1]
    if (!entrySrc) throw new Error('preview / 响应未引用入口 JS')
    const entryRes = await httpGet(cfg.previewPort, entrySrc)
    if (entryRes.status !== 200 || entryRes.body.length === 0) {
      throw new Error(`preview 入口 JS ${entrySrc} 不可访问（HTTP ${entryRes.status}）`)
    }
    notes.push(`preview :${cfg.previewPort} / 与 ${entrySrc} 正常`)
  } finally {
    killChild(preview.child)
    children.delete(preview.child)
  }
  if (!(await waitPortFree(cfg.previewPort))) {
    throw new Error(`preview 服务器回收后端口 ${cfg.previewPort} 仍被占用（服务残留）`)
  }

  // dev：验证开发服务器与核心渲染入口模块可经转换管道加载
  const dev = await startServer('dev 服务器', [], cfg.devPort)
  try {
    if (!dev.firstResponse.body.includes('id="app"')) throw new Error('dev / 响应缺少 #app 挂载点')
    const mainRes = await httpGet(cfg.devPort, '/src/main.js')
    if (mainRes.status !== 200 || !mainRes.body.includes('createApp')) {
      throw new Error(`dev /src/main.js 加载异常（HTTP ${mainRes.status}）`)
    }
    const setupRes = await httpGet(cfg.devPort, '/src/editor/setup.js')
    if (setupRes.status !== 200 || !setupRes.body.includes('createEditor')) {
      throw new Error(`dev /src/editor/setup.js 加载异常（HTTP ${setupRes.status}）`)
    }
    notes.push(`dev :${cfg.devPort} /、/src/main.js、/src/editor/setup.js 正常`)
  } finally {
    killChild(dev.child)
    children.delete(dev.child)
  }
  if (!(await waitPortFree(cfg.devPort))) {
    throw new Error(`dev 服务器回收后端口 ${cfg.devPort} 仍被占用（服务残留）`)
  }

  pass('serve', `启动冒烟通过，服务已全部回收（${notes.join('；')}）`)
}

// ---------------------------------------------------------------- 主流程

const STAGES = [
  { name: 'env', run: checkEnv },
  { name: 'deps', run: checkDeps },
  { name: 'ports', run: checkPorts },
  { name: 'entry', run: checkEntry },
  { name: 'build', run: checkBuild, requires: ['deps'] },
  { name: 'artifacts', run: checkArtifacts, requires: ['build'] },
  { name: 'serve', run: checkServe, requires: ['deps', 'ports', 'artifacts'] }
]

function parseArgs() {
  const args = process.argv.slice(2)
  const get = (flag) => args.find((a) => a.startsWith(`--${flag}=`))?.split('=')[1].split(',').filter(Boolean)
  if (args.includes('--help')) {
    console.log('用法: node scripts/check.mjs [--only=env,deps,ports,entry,build,artifacts,serve] [--skip=serve]')
    process.exit(0)
  }
  return { only: get('only'), skip: get('skip') || [] }
}

async function main() {
  const startedAt = Date.now()
  const { only, skip: skipList } = parseArgs()
  console.log(`== MD Live Editor 基线回归检查 ==（目录: ${ROOT}）\n`)

  for (const stage of STAGES) {
    if (only && !only.includes(stage.name)) continue
    if (skipList.includes(stage.name)) { skip(stage.name, '--skip 指定'); continue }
    const unmet = (stage.requires || []).filter((req) => ran(req) && !results.some((r) => r.stage === req && r.status === 'pass'))
    if (unmet.length) { skip(stage.name, `前置阶段失败: ${unmet.join(', ')}`); continue }
    try {
      await stage.run()
    } catch (err) {
      fail(stage.name, err.message)
    }
  }

  cleanupChildren()
  const failedStages = results.filter((r) => r.status === 'fail')
  const skipped = results.filter((r) => r.status === 'skip')
  console.log(`\n== 汇总: ${results.length - failedStages.length - skipped.length} 通过 / ${failedStages.length} 失败 / ${skipped.length} 跳过（耗时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s）==`)
  if (failedStages.length) {
    console.log(`失败阶段: ${failedStages.map((r) => r.stage).join(', ')}`)
    process.exit(1)
  }
  console.log('基线回归检查全部通过。')
}

main()
