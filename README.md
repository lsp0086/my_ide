# my_ide

基于 Flutter 的轻量桌面 IDE：资源管理器、代码编辑、全文搜索、AI 助手（Chat / Agent）、自研版本管理，以及 WebDAV 配置备份。

面向本地文件夹工作流，界面参考常见编辑器的多栏布局（活动栏 / 侧栏 / 编辑区 / AI 面板），可拖拽调宽。

## 版本更新

### 1.0.4
- **用户编辑接入对话**：用户手动保存文件后记 `user-edit` 版本，并自动挂到最后一条对话气泡，方便回看自己改了什么
- **差异页改造**：从查看节点进入只看红绿行，不再显示变更行数气泡；对话差异页每个变更块右下角新增红色 **N** 回退气泡，点击只回退该块、其余块保留；回退后本轮无剩余改动时提示并同时删除该轮对话
- **单块回退落盘**：目标块留旧删新，其余块保持新文件；无剩余改动时从本轮移除
- **Agent 交互重构**：关键逻辑改状态驱动，修复对话被 UI 移除后顶掉等 bug；审批弹窗改队列串行展示，不再死锁；取消信号级联到子 Agent、在途命令和工具调用
- **多窗口支持**：原生多窗口 + 新进程启动（`open -n` / `--open=` 直达项目），文件树与最近项目加"新窗口打开"入口
- **单项目打开锁**：跨进程 + 进程内双锁，防止多窗口重复打开同一项目；对话进行中锁死新建/删除对话
- **MCP 工具接入**：内置 stdio / Streamable HTTP 两种协议，可增删配置、按工具设只读/可写/网络三级审批与开关，无需外部依赖即可扩展 IDE 能力；MCP 响应增加 deadline、空闲超时与内存上限，避免异常服务导致 Agent 失控运行
- **Skills 管理**：兼容开源 Agent Skills（SKILL.md），多源自动发现（`.agents` / `.cursor` / `.claude` / 全局目录），可启用/禁用、粘贴导入，`/skill-name` 硬路由到技能
- **OpenAI Responses 协议**：新增 `openaiResponses` 格式，支持 `previous_response_id` 多轮复用、内置 `web_search` / `code_interpreter` 工具；兼容 Azure（`api-key` 头）与自定义请求头；修正 `previous_response_id` 与完整 messages 同时下发造成的重复上下文
- **图片多模态消息**：用户消息可带图片（粘贴/拖入），支持视觉模型原生多模态；非视觉模型给出切换提示
- **贡献统计面板**：侧栏 GitHub 风格热力图，按日聚合对话轮次 / token 消耗 / 文件改动 / 耗时，点击某天查看当日详情
- **版本 Redo**：Restore 前自动记当前状态，Redo 栈一键恢复；二进制文件（图片/附件）也纳入版本快照，可回滚；二进制 checkpoint 改用字节 blob 与差量链恢复，修复半恢复数据损坏
- **外部文件冲突三向合并**：脏 tab 被外部改时弹冲突框，可选保留本地 / 载入磁盘 / 行级三向合并，不丢撤销栈
- **问题面板 AI 修复**：每条诊断旁加"AI 修复"按钮，点击自动拼修复指令下发给 AI 面板
- **子 Agent 派生**：`spawn_subagent` 工具让主 Agent 在只读上下文下启动独立子 Agent 执行调研任务，结果汇总返回，不烧主循环 token；主任务取消可级联终止子 Agent
- **对话轮次元数据**：每轮新增 `durationMs`（耗时）、`stopReason`（完成/用户中断/最大步数）、`token` 计数
- **命令沙箱词法级判定**：黑名单升级为分词级（去引号、展开 `$IFS`/`$VAR`/反引号），`rm${IFS}-rf`、`python -c` 等绕过手法不再可用；非白名单命令默认走沙箱审批；只读白名单改为固定 executable + argv，Shell 元字符、管道、重定向、命令替换和复合语句逐次审批
- **命令进程生命周期**：统一 `Process.start` + Runner 级进程管理器持有句柄，超时、取消、会话结束、切换工作区和应用退出均终止整个进程树，避免后台进程继续修改文件或占用资源；后台任务管理器提升为长生命周期服务，修复启动后失联与孤儿进程问题
- **LSP 修复**：字节流解析 `Content-Length`（修复中文长包截断）、`didChange` 增量节流防击键轰炸、客户端驱逐 TTL 防僵尸连接；Windows 命令执行、语言服务安装与 PATH 处理改为平台适配
- **工具注册中心重构**：工具 schema 收敛到单源、审批门禁 FIFO 队列串行化、参数 JSON-Schema 校验+归一化，缺参拒收不落空文件；多文件补丁具备原子提交和失败回滚，只记录替换片段并统一删除/覆盖顺序
- **外部内容隔离**：网页、MCP 与不可信工具结果增加 UNTRUSTED_DATA 围栏和来源标签，见过的外部数据会提升后续写入、命令、MCP 审批等级，阻断 prompt injection 静默写文件；`fetch_url` 默认审批并限制回环、私网、链路本地、组播、元数据地址与重定向
- **会话持久化可靠性**：落盘失败设置 dirty / `lastSaveError` 并重试，AI 面板提示未保存，退出前 `flushUnsaved`，避免"界面成功但未落盘"
- **上下文压缩滚动化**：长会话再次超预算时使用旧摘要 + 尚未摘要消息滚动压缩，避免中间历史永久遗忘；模型请求增加连接、空闲和总量 deadline

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
- 活动栏：文件、搜索、问题、版本、WebDAV、统计、设置
- 亮色 / 暗色主题，中英文界面
- 支持将文件 / 文件夹拖入工作区；文件树与最近项目支持"新窗口打开"入口（多窗口）
- 单项目打开锁：跨窗口/进程防重复打开同一项目；对话进行中锁死新建与删除对话

### 编辑器
- 多标签文本编辑（`re_editor` + `re_highlight`）
- 语法高亮、保存快捷键（默认 ⌘/Ctrl+S）
- 本地完整性检查 + LSP 诊断；gutter / 状态栏 / 问题列表；问题面板每条诊断可一键"AI 修复"
- 图片预览、SVG 预览 / 源码切换
- 外部改写或 AI 写盘后自动刷新已打开文件；脏 tab 被外部改时弹冲突框（保留本地 / 载入磁盘 / 行级三向合并），不丢撤销栈
- Diff 查看：版本页只读红绿行；对话入口每个变更块右下角有红色 N，可单块回退；用户手动保存的文件自动挂到最后一条对话气泡

### 搜索
- 工作区全文搜索（大小写、全词、正则）
- 点击结果直接在编辑器中打开并定位

### 符号跳转
- ⌘/Ctrl + 点击：跳转到定义
- 语言服务器按需下载（首次打开询问）；也可在设置中配置路径或手动安装
- 内置多语言符号索引兜底；在定义处可反向查看引用

### AI 助手
- 供应商协议：默认 OpenAI 兼容；可切换 Anthropic Messages；新增 OpenAI Responses（`previous_response_id` 多轮复用、内置 `web_search` / `code_interpreter`）；兼容 Azure（`api-key` 头）与自定义请求头
- 配置 Base URL / Token（Anthropic 为 x-api-key）、拉取模型、上下文长度、思考档位
- **Chat**：普通对话；**Agent**：可读写工作区文件、搜索、执行命令（高危操作需审批）；`spawn_subagent` 可派生独立只读子 Agent 执行调研任务
- 流式输出、思考内容展开、Markdown 渲染
- 多会话切换；粘贴图片（支持 vision 的模型按多模态发送）；每轮记录耗时与终止原因
- 请求失败可按设置静默重试；上下文过长时自动压缩；对话本地 gzip 落盘

### MCP 与 Skills
- **MCP**：内置 stdio / Streamable HTTP 协议，可增删配置，按工具设只读/可写/网络三级审批与开关
- **Skills**：兼容开源 Agent Skills（SKILL.md），多源自动发现，启用/禁用，`/skill-name` 硬路由

### 统计
- 侧栏 GitHub 风格贡献热力图：按日聚合对话轮次 / token 消耗 / 文件改动 / 耗时，点击某天查看当日详情

### 版本管理（非 Git）
- 自研内容寻址快照（blob / tree / diff），记录用户编辑与 AI 改动；二进制文件也纳入快照可回滚
- 版本面板浏览历史与文件差异（只读红绿行，无气泡）
- 对话侧支持回撤轮次、单文件回退、红色 N 单块回退；无剩余改动时同步删除该轮对话
- Restore 前自动记当前状态，Redo 栈一键恢复现场

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
