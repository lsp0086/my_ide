# my_ide

基于 Flutter 的轻量桌面 IDE：资源管理器、代码编辑、全文搜索、AI 助手（Chat / Agent）、自研版本管理，以及 WebDAV 配置备份。

面向本地文件夹工作流，界面参考常见编辑器的多栏布局（活动栏 / 侧栏 / 编辑区 / AI 面板），可拖拽调宽。

## 功能概览

### 工作区与布局
- 打开 / 关闭文件夹，记住最近项目
- 活动栏：文件、搜索、版本、WebDAV、设置
- 亮色 / 暗色主题，中英文界面
- 支持将文件拖入工作区

### 编辑器
- 多标签文本编辑（`re_editor` + `re_highlight`）
- 语法高亮、保存快捷键（默认 ⌘/Ctrl+S）
- 图片预览、SVG 预览 / 源码切换
- 外部改写或 AI 写盘后自动刷新已打开文件
- Diff 查看：对话入口支持按变更块接受 / 拒绝并合并写回；版本页仅只读浏览

### 搜索
- 工作区全文搜索（大小写、全词、正则）
- 点击结果直接在编辑器中打开并定位

### 符号跳转
- ⌘/Ctrl + 点击：跳转到定义
- 可选外部语言服务器（Dart、TypeScript、Python、Go、Rust、C/C++ 等，路径可在设置中配置）
- 内置多语言符号索引兜底；在定义处可反向查看引用

### AI 助手
- OpenAI 兼容接口：配置 Base URL / Token、拉取模型、上下文长度、思考档位
- **Chat**：普通对话；**Agent**：可读写工作区文件、搜索、执行命令（高危操作需审批）
- 流式输出、思考内容展开、Markdown 渲染
- 多会话切换；粘贴图片（支持 vision 的模型按多模态发送）
- 上下文过长时自动压缩；对话本地 gzip 落盘

### 版本管理（非 Git）
- 自研内容寻址快照（blob / tree / diff），记录用户编辑与 AI 改动
- 版本面板浏览历史与文件差异（只读）
- 对话侧支持回撤轮次、单文件回退等精细操作

### 设置与备份
- 主题、高亮、语言、供应商、最近项目、语言服务器路径等本地持久化
- WebDAV：登录后备份 / 恢复设置与供应商配置

## 技术栈

- Flutter / Dart 3（桌面：macOS；Windows / Linux 需在对应系统或 CI 构建）
- 主要依赖：`re_editor`、`re_highlight`、`http`、`shared_preferences`、`desktop_drop`、`clipboard`、`flutter_markdown`、`crypto`

## 运行

```bash
flutter pub get
flutter run -d macos
```

其他桌面平台需在对应操作系统上启用并构建，例如：

```bash
flutter config --enable-windows-desktop
flutter build windows --release
```

## 本地发布（本机可编平台）

```bash
./scripts/release_desktop.command
```

默认将产物输出到 `dist/`，并执行 `flutter clean`。macOS 上通常只能打出 macOS 包；Windows / Linux 包需在对应主机或 GitHub Actions 的 Windows / Linux runner 上构建。

## 目录提示

| 路径 | 说明 |
| --- | --- |
| `lib/ui/` | 主界面、编辑器、Diff、版本 / WebDAV 面板 |
| `lib/ai/` | 对话、Agent、供应商客户端、上下文压缩 |
| `lib/version/` | 自研 checkpoint 存储 |
| `lib/lsp/` | LSP 客户端与内置符号 / 引用索引 |
| `lib/settings/` | 设置持久化 |
| `lib/workspace/` | 工作区与文件树 |
| `scripts/` | 桌面发布脚本 |

## 说明

- 本项目的版本管理是独立的内容寻址快照，**不替代 Git**。
- AI Agent 的文件与命令操作受工作区门禁与审批策略约束。
- Windows 桌面包无法在 macOS 本机交叉编译，需 Windows 环境或 CI。
