# my_ide

基于 Flutter 的轻量桌面 IDE：资源管理器、代码编辑、全文搜索、AI 助手（Chat / Agent）、自研版本管理，以及 WebDAV 配置备份。

面向本地文件夹工作流，界面参考常见编辑器的多栏布局（活动栏 / 侧栏 / 编辑区 / AI 面板），可拖拽调宽。

## 版本更新

### 1.0.3
- 新增 **代码完整性 / 行号正确性检查**：本地括号与引号检查，JSON 可解析校验；统一 0-based 行号与文档版本失效
- 诊断呈现最小三件套：**行号旁 gutter 标记**、**状态栏 ✕/⚠ 计数**、**问题侧栏列表**（点击跳转）
- 扩展 LSP：接收 `textDocument/publishDiagnostics`，与本地检查按来源合并
- 语言服务改为多语言按需能力（后续版本改为询问下载，不再预置进安装包）
- Dart 仍使用本机 SDK 自带 Analysis Server
- 上下文长度选择改为弹出面板，避免竖向下拉裁切

### 1.0.2
- AI 供应商新增 **API 格式切换**：默认仍为 OpenAI 兼容；可选 Anthropic（`/v1/messages` + `x-api-key`），不改动既有 OpenAI 请求路径
- Agent 参数新增 **重试轮数**（默认 5）：请求非 2xx 时静默重试，始终复用初次请求内容，全部失败后再报错
- 默认最大步数由 25 调整为 **45**

### 1.0.1
- 更新 **清除记忆**：支持清空项目记忆，以及删除对话时合并 / 清理关联差异版本
- 添加 **拖入文件** 逻辑：可将文件 / 文件夹拖入工作区导入并记版本；也可拖到对话输入区作为附件
- 更新 **精细版本管理**：支持按变更块接受 / 拒绝并合并写回；版本页仅只读浏览

## 功能概览

### 工作区与布局
- 打开 / 关闭文件夹，记住最近项目
- 活动栏：文件、搜索、问题、版本、WebDAV、设置
- 亮色 / 暗色主题，中英文界面
- 支持将文件拖入工作区

### 编辑器
- 多标签文本编辑（`re_editor` + `re_highlight`）
- 语法高亮、保存快捷键（默认 ⌘/Ctrl+S）
- 本地完整性检查 + LSP 诊断；gutter / 状态栏 / 问题列表
- 图片预览、SVG 预览 / 源码切换
- 外部改写或 AI 写盘后自动刷新已打开文件
- Diff 查看：对话入口支持按变更块接受 / 拒绝并合并写回；版本页仅只读浏览

### 搜索
- 工作区全文搜索（大小写、全词、正则）
- 点击结果直接在编辑器中打开并定位

### 符号跳转
- ⌘/Ctrl + 点击：跳转到定义
- 语言服务器按需下载（首次打开询问）；也可在设置中配置路径或手动安装
- 内置多语言符号索引兜底；在定义处可反向查看引用

### AI 助手
- 供应商协议：默认 OpenAI 兼容；可切换 Anthropic Messages
- 配置 Base URL / Token（Anthropic 为 x-api-key）、拉取模型、上下文长度、思考档位
- **Chat**：普通对话；**Agent**：可读写工作区文件、搜索、执行命令（高危操作需审批）
- 流式输出、思考内容展开、Markdown 渲染
- 多会话切换；粘贴图片（支持 vision 的模型按多模态发送）
- 请求失败可按设置静默重试；上下文过长时自动压缩；对话本地 gzip 落盘

### 版本管理（非 Git）
- 自研内容寻址快照（blob / tree / diff），记录用户编辑与 AI 改动
- 版本面板浏览历史与文件差异（只读）
- 对话侧支持回撤轮次、单文件回退等精细操作

### 设置与备份
- 主题、高亮、语言、供应商、最近项目、语言服务器路径等本地持久化
- WebDAV：登录后备份 / 恢复设置与供应商配置

## 技术栈

- Flutter / Dart 3（桌面：macOS；Windows / Linux 需在对应系统或 CI 构建）
- 主要依赖：`re_editor`、`re_highlight`、`http`、`shared_preferences`、`desktop_drop`、`clipboard`（本地 fork：`packages/clipboard`，修复 Windows MSVC C4189）、`flutter_markdown`、`crypto`

## 推荐 Flutter 版本

本地与 CI 统一使用：

| 项目 | 版本 |
| --- | --- |
| Flutter | **3.38.6**（stable） |
| Dart SDK | 3.10.7 |
| Framework revision | `8b87286849` |

GitHub Actions（`.github/workflows/release-desktop.yml`）已固定 `flutter-version: '3.38.6'`。本机请尽量使用同一版本，避免桌面插件 / MSVC / 引擎差异。

可用以下命令核对：

```bash
flutter --version
# 期望包含：Flutter 3.38.6 • channel stable
```

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

### macOS：带语言服务的 Release（测诊断请用这个）

只执行 `flutter build macos --release` **不会**带语言包。请用：

```bash
bash tool/package_macos_release.sh
```

该脚本会：

1. `flutter build macos --release`
2. 精简后压缩为 `.tar.zst`，写入 `*.app/Contents/Resources/language_archives/`
3. 附带便携 `zstd`；输出 `dist/my_ide-*-macos.zip`

验证：

```bash
APP="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
ls -lh "$APP/Contents/Resources/language_archives"/*.tar.zst
```

首次打开 `.js` 时会解压到 `~/Library/Application Support/.../languages/`，问题面板应出现 `Cannot find name 'consle'`。  
参考体积（压缩后，约）：node ~几十 MB、typescript ~8MB、pyright ~3MB；远小于此前未压缩的 ~347MB 语言目录。

## 目录提示

| 路径 | 说明 |
| --- | --- |
| `lib/ui/` | 主界面、编辑器、Diff、版本 / WebDAV 面板 |
| `lib/ai/` | 对话、Agent、供应商客户端、上下文压缩 |
| `lib/version/` | 自研 checkpoint 存储 |
| `lib/lsp/` | LSP 客户端与内置符号 / 引用索引 |
| `lib/diagnostics/` | 本地完整性检查与诊断仓库 |
| `lib/settings/` | 设置持久化 |
| `lib/workspace/` | 工作区与文件树 |
| `tool/` | 语言服务预置与 macOS 打包脚本 |
| `scripts/` | 桌面发布脚本 |
| `packages/clipboard` | 本地 clipboard fork（Windows 编译修复） |
| `.github/workflows/` | 桌面三端 Release CI |

## 说明

- 本项目的版本管理是独立的内容寻址快照，**不替代 Git**。
- AI Agent 的文件与命令操作受工作区门禁与审批策略约束。
- Windows 桌面包无法在 macOS 本机交叉编译，需 Windows 环境或 CI。
- `clipboard` 已改为 path 依赖，本地脚本与 GitHub Actions 都只需 `flutter pub get` + `flutter build …`，无需再运行时 patch。
