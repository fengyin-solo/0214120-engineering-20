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

### 回归检查

```bash
cd frontend-editor
npm run check
```

## 可复现基线

### 环境基线

- Node >= 18、npm >= 9（`frontend-editor/package.json` 的 `engines` 声明）
- 依赖按 `package-lock.json` 锁定；Docker 构建使用 `npm ci` 严格复现
- 环境变量以 `frontend-editor/.env.example` 为唯一声明清单，复制为 `.env` 后按需修改：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `VITE_DEV_HOST` | `0.0.0.0` | dev / preview 监听地址 |
| `VITE_DEV_PORT` | `5173` | dev 服务器端口 |
| `VITE_PREVIEW_PORT` | `4173` | preview 服务器端口 |

端口被占用时 dev / preview 会立即报错退出（`strictPort`），不会静默切换端口。

### 回归检查覆盖（`npm run check`）

| 阶段 | 检查内容 | 失败时的明确结果 |
|------|----------|------------------|
| env | Node/npm 版本、`.env` 与进程环境中的未知变量、端口变量合法性 | 列出全部未知变量与非法值 |
| deps | `node_modules`、声明依赖、平台原生依赖（rollup/esbuild） | 列出缺失依赖及修复命令 |
| ports | dev / preview 端口未被占用 | 列出被占用的端口 |
| entry | `#app` 挂载、`createEditor` 入口、Markdown 区域解析自检 | 指出缺失的入口或自检失败项 |
| build | `npm run build` 必须成功 | 退出码非 0 并附构建日志尾部 |
| artifacts | `dist/index.html` 与入口 JS 产物存在且非空 | 指出缺失的产物文件 |
| serve | dev 与 preview 服务器启动冒烟（`/`、入口模块、入口产物） | 指出不可访问的地址 |

约束：检查只读取业务源码、不做任何改写；冒烟启动的服务在退出前无条件回收，不残留进程。支持 `--only=env,deps` 与 `--skip=serve` 参数做局部检查（见 `node scripts/check.mjs --help`）。

## Services

| 服务 | 地址 | 说明 |
|------|------|------|
| MD Live Editor | http://localhost:8081 | Docker 部署 |
| MD Live Editor (dev) | http://localhost:5173 | 本地开发 |
| MD Live Editor (preview) | http://localhost:4173 | 构建产物预览 |

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
