# my_ide

基于 Flutter 的轻量桌面 IDE：资源管理器、代码编辑、全文搜索、AI 助手（Chat / Agent）、自研版本管理，以及 WebDAV 配置备份。

面向本地文件夹工作流，界面参考常见编辑器的多栏布局（活动栏 / 侧栏 / 编辑区 / AI 面板），可拖拽调宽。

## 版本更新

### 1.0.5
- **Agent 与审批**：只读批取消感知收集（50ms复检早退，未收集回中断占位）；写/命令/终端审批后执行前取消复检；预算计入子Agent输出；多模态裁剪跳过List结构；`todo_write`同id冲突盘上优先+判脏加size维度；切换项目运行时会话保持
- **写冲突与文件安全**：搜索上下文回读钳制审批目录内；删除预览/复制源端/回收站恢复补link检查；后台冲突目录级前缀匹配
- **MCP**：安装目录删除收敛到应用托管根（`~/.cache/my_ide/mcp-installs`下两层），系统前缀与HOME缺失fail-closed

### 1.0.4
- **版本管理**：手动保存记 `user-edit` 并挂气泡；版本页只看红绿行；支持单块/单文件/整轮回退；超 3 文件折叠；Restore 前自动记现场可 Redo；二进制纳入快照；版本库损坏直接报错；补记漂移与防抖版本；checkpoint 附 git 状态；回滚/快照恢复全走原子写；drop 持锁防并发（回退借位重入）；manifest 备份经 `.new` 原子转正；快照跳过口径对齐；恢复提交前复检；侧车名加随机
- **写冲突与崩溃恢复**：写盘前查脏缓冲，保存前比 mtime 转冲突抉择，手动保存同样走冲突门禁 + 覆盖二次确认；每批次写 journal，重启恢复中断；脏编辑器定时落盘；落盘失败标 dirty 重试 + 退出 flush；随机侧车名原子写（含编辑器手动保存）；落盘前二次复检；乐观锁 + 后台冲突确认；快照超限强制确认；空白 `oldText` 直接拒绝防文件头误插；补丁同文件按绝对路径去重、提交重读限 1MB；移动/写/改预览补链检查；todos 侧车加随机；回收站命名加 pid/随机、恢复剥离对齐防错位
- **Agent 与审批**：状态驱动 + 审批队列串行，超时按项移除，取消级联；子 Agent 按实例隔离、世代丢弃（含 progress 回调隔离）、同批并发不误拒，用量计入预算熔断（新轮按在途重建预占防空窗，子预算加回工具输出防低估）；只读可并行、写串行，超时熔断回填占位，只读批取消即回中断，重复 tool_call.id 首个 wins；`todo_write` 禁 Chat/Plan 落盘；安全命令本轮信任 + 自动审批规则；命令沙箱分词判定，终端状态变更强制再审；统一进程树管理；敏感路径永拒；密钥 v3 随机 nonce；docker 去硬编码用户；命令气泡随对话落盘；运行中会话锁定，回退/删除/清空/并发压缩在运行中拒绝；历史提级含压缩摘要与命令输出；中途裁剪扩至正文大段
- **MCP / Skills / 规则**：MCP 内置 stdio/Streamable HTTP，三级审批与开关，resources/prompts 聚合为只读工具，工具聚合快照遍历防并发修改，重连加代际防禁用后复活；响应加 deadline/超时/内存上限（截断 + 节流）；Skills 兼容 SKILL.md，多源发现 + 硬路由，导入加名称规范与路径越界门禁、外链删除拦截、SKILL.md 原子写；子代理只读派生；`AGENTS.md` 每轮注入；composer 模板 chip；会话可分叉；`mcp_get_prompt` 支持带参；项目规则按改动文件自动挂载
- **多窗口与外部打开**：原生多窗口 + 新进程直达项目；双锁防重复打开，对话运行中锁回退/删除/清空；支持 Finder/Dock 拖入；标签/活动态持久化，启动重开最近项目；工作区 dispose 后在途监听不再刷 UI
- **模型与上下文**：OpenAI Responses（复用 + `web_search`/`code_interpreter`），兼容 Azure 与自定义头/参数；图片多模态，落盘为 `chat_assets` 引用；每轮记耗时/stopReason/token；超预算滚动压缩；请求加 deadline
- **搜索/诊断/LSP**：`search_text` 重排；新增 `repo_map`/`semantic_search`/`lsp_definition`/`lsp_references` 只读工具并可并行；问题面板一键"AI 修复"；LSP 修截断、didChange 真节流合并、防僵尸连接、订阅取消 await，Windows 适配，支持自定义服务；外部 lint 聚合并做参数隔离与截断；诊断统一标不可信并提级；结构化日志
- **编辑器**：大文件窗口化只读，支持"加载全部"/局部编辑两种放行路径
- **发布**：Windows 打包改 `pwsh` 原生压缩，不再经 bash 调 powershell；CI 沿用三端 analyze + 全量测试
- **其他**：贡献统计热力图；外部内容 UNTRUSTED_DATA 围栏 + 审批提级，`fetch_url` 限私网/元数据地址；WebDAV 恢复加版本校验、MCP 命令白名单、审批值白名单、skills 路径穿越过滤

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
- 配置 Base URL / Token（Anthropic 为 x-api-key）、拉取模型、上下文长度、思考档位、模型自定义参数（表格每行一对 key/value，均非空才保存）
- **Chat**：普通对话；**Agent**：可读写工作区文件、搜索、执行命令（高危操作需审批）；`spawn_subagent` 可派生独立只读子 Agent 执行调研任务
- 操作审批：区内写/区外写/删除/命令/MCP 五档全局 + 逐工具·路径自动审批规则（deny 优先），审批队列串行，取消级联子 Agent 与命令
- 流式输出、思考内容展开、Markdown 渲染
- 多会话切换；粘贴图片（支持 vision 的模型按多模态发送，气泡缩略展示）；每轮记录耗时与终止原因
- 请求失败可按设置静默重试；上下文过长时自动压缩；对话本地 gzip 落盘，图片存 `.my_ide/chat_assets` 独立文件

### MCP 与 Skills
- **MCP**：内置 stdio / Streamable HTTP 协议，可增删配置，按工具设只读/可写/网络三级审批与开关；resources/prompts 聚合为只读 Agent 工具（输出标 untrusted，可并行）
- **Skills**：兼容开源 Agent Skills（SKILL.md），多源自动发现，启用/禁用，`/skill-name` 硬路由
- **规则**：工作区根 `AGENTS.md` 每轮注入（8K 截断）；**模板**：composer"模板" chip，内置 + 项目 `.my_ide/prompts/*.md`（`{{input}}` 占位）；**分叉**：从指定消息截断复制为新会话

### 统计
- 侧栏 GitHub 风格贡献热力图：按日聚合对话轮次 / token 消耗 / 文件改动 / 耗时，点击某天查看当日详情

### 版本管理（非 Git）
- 自研内容寻址快照（blob / tree / diff），记录用户编辑与 AI 改动；二进制文件也纳入快照可回滚
- 版本面板浏览历史与文件差异（只读红绿行，无气泡）
- 对话侧支持回撤轮次、单文件回退、红色 N 单块回退；超 3 个文件改动折叠 + 总览弹窗；无剩余改动时同步删除该轮对话
- Restore 前自动记当前状态，Redo 栈一键恢复现场；版本库损坏缺 tree 即报错，不会清空工作区
- 打开项目补记关闭后漂移，运行中外部改动防抖记 `user-edit`（AI 对话中跳过）；checkpoint 附带 git 分支/commit/脏状态

### 设置与备份
- 主题、高亮、语言、供应商、最近项目、语言服务器路径等本地持久化
- WebDAV：登录后备份 / 恢复设置与供应商配置
- 工作区标签/活动态持久化，启动重开最近项目；macOS 支持 Finder/Dock 拖入外部打开
- 诊断：内存 500 条 + `.my_ide/logs/app.log` 轮转；请求/上下文 deadline、失败重试与 dirty 提示
- 跨平台 CI：push/PR 在 ubuntu/windows/macos 跑 analyze + 全量测试

### 已知待办
- 回退前对树外改动做隐式 checkpoint；"保留本地"后二次确认；未挂载脏 tab 缓冲取回；拖入语义（复制导入 vs 加入工作区）；git shadow 回退 / 遥测上报暂不做

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
默认将产物输出到 `dist/`，构建前执行 `flutter analyze --no-fatal-infos` 和 `flutter test`，并为每个压缩包生成 `.sha256` 校验文件；使用 `--skip-check` 可跳过检查，使用 `--no-clean` 可保留 `build/`。macOS 产物命名包含当前架构。macOS 上通常只能打出 macOS 包；Windows / Linux 包需在对应主机或 GitHub Actions 的 Windows / Linux runner 上构建。

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
