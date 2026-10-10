# my_ide

基于 Flutter 的轻量桌面 IDE：资源管理器、代码编辑、全文搜索、AI 助手（Chat / Agent）、自研版本管理，以及 WebDAV 配置备份。

面向本地文件夹工作流，界面参考常见编辑器的多栏布局（活动栏 / 侧栏 / 编辑区 / AI 面板），可拖拽调宽。

## 版本更新

### 1.0.5
- **Agent 与审批**：只读并行 + 写串行调度、审批后复检；会话/排队/规则分桶与 glob 通配、追问轮末续轮；子 Agent 按步聚合与整批超时，超时按 spawnId 精确取消；token 增量入账防双计；审批超时/拒绝/取消三口径可区分（超时可重试）；untrusted 外联及网络命令恒提级；429 按 Retry-After、5xx 指数退避；命令重定向分区；MCP 敏感兜底、日志打码、导出去 token、毒配置持久化禁用；三档沙箱 + Docker 包装（镜像可配）；hook sha256 钉死并记审计行；cron 分桶与固定频率；用量 NaN/Infinity 钳制
- **文件安全与版本**：拒链接/越界 + 乐观锁 + 提交期重读；同文件写串行；journal/manifest fail-closed、GC 不误删 live；恢复拒绝覆盖未记录改动，失败回滚按提交前字节；大文件直通 + 版本 diff 贪心防 OOM；对话图片限 5 种位图（魔数 + 8MB）；轨迹导出含子 Agent；补丁说明支持 Conventional Commits 校验；WebDAV 密码与设置写盘串行防撕裂
- **自研浏览器**：30 工具 + SSRF 校验；click/fill 走 Input 域、select/fill 统一 base64；wait_for 显式等待防 SPA 空骨架；上传/下载工作区门禁防 TOCTOU；Chrome 退出同步关 CDP；弹窗按子会话路由；控制台脱敏与敏感 query 掩码；iframe 穿透查询、evaluate 超时终止；click/hover 遮挡检查；视口/UA 模拟；连接世代防串扰，资源释放有界
- **编辑器与诊断**：大文件窗口化；诊断 gutter 不在布局期 setState；快捷键落盘；粘贴图片先判大小；本地检查 + LSP 合并（JSON 偏移映射、行列钳制、非法 glob 回空）；终端 unset 全分隔符检出；密钥与日志脱敏补全（含审计行）

### 1.0.4
- **版本与恢复**：完善用户/AI 编辑快照、单块/单文件/整轮回退、Redo、二进制快照、Git 状态记录与损坏校验；回滚、快照和 manifest 均采用原子写与并发保护。
- **写入安全与崩溃恢复**：增加脏缓冲/mtime/后台修改冲突确认、乐观锁、补丁与链接校验、journal 中断恢复、定时落盘重试、回收站及 todos 侧车安全处理。
- **Agent、审批与子 Agent**：审批队列、取消级联、超时熔断、只读并行/写串行、预算控制、命令沙箱、终端状态复审、敏感路径保护、运行中会话锁及外部内容提级。
- **MCP、Skills 与规则**：支持 stdio/Streamable HTTP、resources/prompts、三级审批、超时限流、SKILL.md 多源发现与硬路由、路径/外链校验、子代理只读派生，以及每轮注入 `AGENTS.md`。
- **窗口、模型与上下文**：支持多窗口、项目去重锁、Finder/Dock 拖入、Responses/Azure/自定义协议、图片引用、多模态、token 统计、请求 deadline 与上下文压缩。
- **搜索、诊断与编辑器**：新增 repo map、语义搜索、LSP 定义/引用等并行只读工具；完善诊断、外部 lint、问题修复入口、大文件窗口化编辑及结构化日志。
- **发布与其他**：Windows 改用 `pwsh` 原生打包，CI 保持三端检查；补充 WebDAV 版本校验、贡献统计、UNTRUSTED_DATA 围栏、私网限制及密钥/路径安全。

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
- 未挂载脏 tab 缓冲落侧车（`.my_ide/drafts/`，sha1 文件名防穿越）：切走 tab / 关窗口不丢未保存内容，下次打开自动恢复；发送前自动落侧车再记快照
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
- **自研浏览器（Agent 专属）**：无侧栏、无独立页面，只能由 Agent 经 `browser_*` 30 工具调用；`browser_open` 打开页面即在编辑器区唤起"页面标签页"（复用 headless Chrome 的 CDP `Page.startScreencast` 帧流渲染，零原生依赖），交互（点击/输入/eval/刷新/切页）全部由 Agent 执行（默认自动审核，输出标untrusted）
- 操作审批：区内写/区外写/删除/命令/浏览器/抓取/区外读/MCP 八档全局（默认除删除文件外全部自动审核）+ 逐工具·路径自动审批规则（deny 优先），审批队列串行，取消级联子 Agent 与命令；高危二次复核开关（默认关闭，开启后高危命令强制弹窗）
- 流式输出、思考内容展开、Markdown 渲染
- 多会话切换；粘贴图片（支持 vision 的模型按多模态发送，气泡缩略展示）；每轮记录耗时与终止原因
- 请求失败可按设置静默重试；上下文过长时自动压缩；对话本地 gzip 落盘，图片存 `.my_ide/chat_assets` 独立文件

### MCP 与 Skills
- **MCP**：内置 stdio / Streamable HTTP 协议，可增删配置，按工具设只读/可写/网络三级审批与开关；resources/prompts 聚合为只读 Agent 工具（输出标 untrusted，可并行）
- **Skills**：兼容开源 Agent Skills（SKILL.md），多源自动发现，启用/禁用，`/skill-name` 硬路由
- **规则**：工作区根 `AGENTS.md` 每轮注入（8K 截断，缺失回退 `CLAUDE.md`/`.cursorrules`/`.windsurfrules`首个存在者）；**模板**：composer"模板" chip，内置 + 项目 `.my_ide/prompts/*.md`（`{{input}}` 占位）；**分叉**：从指定消息截断复制为新会话

### 统计
- 侧栏 GitHub 风格贡献热力图：按日聚合对话轮次 / token 消耗 / 文件改动 / 耗时，点击某天查看当日详情

### 版本管理（非 Git）
- 自研内容寻址快照（blob / tree / diff），记录用户编辑与 AI 改动；二进制文件也纳入快照可回滚
- 版本面板浏览历史与文件差异（只读红绿行，无气泡）
- 对话侧支持回撤轮次、单文件回退、红色 N 单块回退；超 3 个文件改动折叠 + 总览弹窗；无剩余改动时同步删除该轮对话；中断轮（用户中断/取消）的版本节点保留在链中可从版本面板恢复，不随对话回退删除
- Restore 前自动记当前状态，Redo 栈一键恢复现场；影子仓（`versions/shadow/` 第二副本，默认开启）兜底 manifest 损坏重建；版本库损坏缺 tree 即报错，不会清空工作区
- 打开项目补记关闭后漂移，运行中外部改动防抖记 `user-edit`（AI 对话中跳过）；checkpoint 附带 git 分支/commit/脏状态；git 锚点自动 commit + 高风险前 push + 大改动前 backup 分支均有开关（默认关闭）

### 设置与备份
- 主题、高亮、语言、供应商、最近项目、语言服务器路径等本地持久化
- WebDAV：登录后备份 / 恢复设置与供应商配置
- 工作区标签/活动态持久化，启动重开最近项目；macOS 支持 Finder/Dock 拖入外部打开
- 诊断：内存 500 条 + `.my_ide/logs/app.log` 轮转；本地遥测开关（默认关闭，仅落盘 `.my_ide/logs/telemetry.log`，不做远端上报）；请求/上下文 deadline、失败重试与 dirty 提示
- 跨平台 CI：push/PR 在 ubuntu/windows/macos 跑 analyze + 全量测试

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

> **macOS 27+ 自编译提醒**：新版 Xcode 下 Flutter 3.38.6 存在 thinFramework bug——通用双架构 `ARCHS="arm64 x86_64"` 透传给 `lipo -verify_arch`（一次只接受单架构）必失败。自编译请与 CI（`.github/workflows/release-desktop.yml`）保持一致，使用本机单架构：
>
> ```bash
> FLUTTER_XCODE_ARCHS="$(uname -m)" FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES flutter build macos --release
> ```
>
> `tool/package_macos_release.sh` 与 `scripts/release_desktop.command` 同理，可在命令前加上述两个环境变量。

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

### macOS：轻量 Release（语言服务按需下载）

`tool/package_macos_release.sh` 会执行 `flutter build macos --release`，清理旧的预置语言包后输出 `dist/my_ide-*-macos.zip`。语言服务不随安装包发布，首次打开对应文件时按应用提示下载到 Application Support。

```bash
bash tool/package_macos_release.sh
```

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
