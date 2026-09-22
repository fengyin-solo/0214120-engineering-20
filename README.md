# MD Live Editor

一个基于 Vue 3 + CodeMirror 6 的 Markdown 即时渲染编辑器。实现类似 Typora 的所见即所得编辑体验——光标所在区域显示语法标记，离开后自动渲染为格式化效果，切换过程平滑无割裂。

## How to Run

### Docker 方式（推荐）

```bash
docker-compose up --build -d
```

### 本地开发

```bash
cd frontend-editor
npm install
npm run dev
```

### 基线检查（可复现）

一条命令固化本地开发、构建、环境配置、端口与回归检查：

```bash
cd frontend-editor
npm run check:baseline
```

检查依次覆盖 9 个阶段：运行环境（Node 20，见 `.nvmrc`）→ 依赖完整性（含 rollup 平台原生绑定）→ 环境变量登记（未知变量失败）→ 业务源码保护快照 → 端口占用预检（dev 5173 / preview 4173）→ dev 启动与核心渲染入口冒烟 → 生产构建 → 产物完整性 → preview 回归。

- 覆盖的渲染入口：HTML 外壳 `#app`、`src/main.js`（createApp/createPinia）、`src/App.vue`（Toolbar/EditorPane/StatusBar）、`src/components/EditorPane.vue`（CodeMirror 挂载入口）、全局 SCSS；preview 侧另验入口 JS 资源与 SPA 深链接回退。
- 每种失败都有独立退出码：`10` 环境不符、`11` 依赖缺失、`12` 未知变量、`13` 端口占用、`14` dev 冒烟失败、`15` 构建失败、`16` 产物缺失、`17` preview 回归失败、`18` 业务源码被改写。
- 检查启动的 dev/preview/build 均运行在独立进程组，结束（含失败与 Ctrl-C）一律回收，并复核端口真正关闭；受保护业务源码（`src/`、`index.html`、构建配置）前后做 SHA-256 比对，零改动才算通过（`dist/`、`node_modules/` 不在保护范围）。
- 端口可按需覆盖：`npm run check:baseline -- --dev-port 5174 --preview-port 4180`。
- 环境变量采用登记制：新增变量需先写入 `frontend-editor/.env.example`；`.env` / `.env.local` 中出现未登记变量会以退出码 `12` 失败。


## Services

| 服务 | 地址 | 说明 |
|------|------|------|
| MD Live Editor | http://localhost:8081 | Docker 部署 |
| MD Live Editor (dev) | http://localhost:5173 | 本地开发 |

## 测试账号

本项目为纯前端编辑器，无需登录。

## 图片插入说明

### 支持的图片格式

编辑器支持标准 Markdown 图片语法：`![替代文本](图片地址)`

### 图片路径类型

1. **网络图片（推荐）**
   - HTTP/HTTPS 地址：`![示例](https://example.com/image.png)`
   - 协议相对地址：`![示例](//example.com/image.png)`

2. **本地文件系统路径（不支持）**
   - ❌ Windows 路径：`![图片](C:\Users\username\image.png)`
   - ❌ Mac/Linux 路径：`![图片](/Users/username/image.png)`
   - ❌ 相对路径：`![图片](./images/photo.jpg)`

### 为什么不支持本地路径？

出于安全考虑，现代浏览器禁止网页直接访问用户本地文件系统。即使输入了正确的本地路径，浏览器也会拒绝加载图片。

### 解决方案

如需使用本地图片，请采用以下方式之一：

1. **上传到图床**：将图片上传到图床服务（如 imgur、SM.MS 等），使用返回的网络地址
2. **本地服务器**：使用本地 HTTP 服务器托管图片，通过 `http://localhost:port/image.png` 访问
3. **Base64 编码**：将小图片转换为 Base64 编码嵌入（不推荐大图片）

### 常见错误示例

```markdown
# 错误：语法颠倒
![C:\Users\benzhi\Desktop\BenZhiTec](错误示范)
# 正确语法应该是：
![错误示范](C:\Users\benzhi\Desktop\BenZhiTec)
# 但即使语法正确，本地路径仍然无法在浏览器中显示

# 正确：使用网络图片
![错误示范](https://example.com/error-demo.png)
```

### 错误提示说明

- **"浏览器无法访问本地路径"**：输入了 Windows/Mac/Linux 本地文件系统路径
- **"图片加载失败"**：网络图片地址无效或无法访问
- **"未指定路径"**：图片语法中缺少 URL 部分

## 题目内容

开发一个 Markdown 即时渲染编辑器，核心功能：

- 用户能够无损编辑 Markdown 文件并看到渲染效果
- 当光标所在区域存在语法标记时，展示语法标记（编辑模式）
- 当光标离开时，展示渲染效果（预览模式）
- 语法标记和渲染效果切换过程中，用户体验不能割裂
- 非双列模式，即时渲染

### 技术实现

- 基于 CodeMirror 6 的 Decoration 系统实现行内渲染
- 通过 ViewPlugin 监听光标位置，动态切换语法标记的显示/隐藏
- CSS transition 实现平滑过渡动画
- 底层始终保持原始 Markdown 文本，渲染仅是视觉层装饰
