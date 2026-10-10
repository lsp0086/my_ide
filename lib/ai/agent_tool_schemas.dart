/// Agent 工具 schema 单一来源。
/// 项目内所有工具定义只在这里维护，禁止在 Runner / Client / 子 Agent 里再手写第二份。
/// - 主循环用 [base] + MCP 工具
/// - 子 Agent 用 [readOnly]（只读子集）
/// - AgentClient.buildTools 仅作兼容转发，不再是真源
class AgentToolSchemas {
  /// 子 Agent 允许的只读工具名。
  /// R13R2：browser_screenshot 回退——截图落盘 tmp 无写语义但占磁盘/需 Chrome，
  /// 此前只读集含 screenshot，子 Agent 并行截图可撑爆 myide-shots（20张轮转但
  /// 高频并发仍抖动）。回退为仅主循环可用，子 Agent 经 blockedTools 拒绝。
  static const readOnlyNames = <String>{
    'read_file',
    'list_files',
    'search_text',
    'read_media',
    'git_status',
    'git_diff',
    'git_preflight',
    'git_blame',
    'fetch_url',
    'browser_read',
    'browser_snapshot',
    'browser_wait',
    'browser_wait_network_idle',
    'browser_console',
    'browser_network',
    'browser_status',
    'browser_targets',
    'browser_frames',
    'mcp_list_resources',
    'mcp_read_resource',
    'mcp_list_prompts',
    'mcp_get_prompt',
    'repo_map',
    'semantic_search',
    'lsp_definition',
    'lsp_references',
  };

  /// 主循环全量基础 schema（不含 MCP，MCP 由 Runner 动态追加）。
  static List<Map<String, dynamic>> base() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'read_file',
          'description': '读取文件内容。工作区内用相对路径；用户附件若给出相对路径可直接读。工作区外用绝对路径（需审批）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'limit': {'type': 'integer'},
              'offset': {'type': 'integer'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'list_files',
          'description': '列出目录内容。工作区内用相对路径（默认根目录）；用户附件文件夹可用其路径，区外绝对路径需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'search_text',
          'description':
              '全文搜索（走 isolate，不卡 UI）。query 为关键词/正则；'
              'include 按后缀或 glob 过滤如 .dart；regex=true 用正则；'
              'caseSensitive/wholeWord 可选；contextLines 返回上下 N 行；maxResults 上限；'
              'excludeDirs 按目录名/相对路径排除如 ["build", "test/fixtures"]。',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'path': {'type': 'string'},
              'include': {'type': 'string'},
              'regex': {'type': 'boolean'},
              'caseSensitive': {'type': 'boolean'},
              'wholeWord': {'type': 'boolean'},
              'contextLines': {'type': 'integer'},
              'maxResults': {'type': 'integer'},
              'excludeDirs': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['query'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'git_status',
          'description': '读取工作区本地 Git 状态，返回结构化的文件级变更与摘要。不执行写操作、不访问远程。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'includeUntracked': {'type': 'boolean'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'git_diff',
          'description': '读取工作区本地 Git diff，返回文件级与 hunk 级结构化变更。不执行写操作、不访问远程。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'staged': {'type': 'boolean'},
              'contextLines': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'git_preflight',
          'description':
              '只读执行本地 Git 提交前检查，返回结构化统计、风险/敏感文件和提交信息建议。不会执行 commit 或 push。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'staged': {'type': 'boolean'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'git_blame',
          'description': '只读执行本地 git blame，返回指定文件行区间的变更归因。不执行写操作、不访问远程。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'startLine': {'type': 'integer'},
              'lineCount': {'type': 'integer'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'ask_question',
          'description': '向用户提问以澄清需求。question 为问题，options 为候选答案列表。',
          'parameters': {
            'type': 'object',
            'properties': {
              'question': {'type': 'string'},
              'options': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['question'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'spawn_subagent',
          'description':
              '派生子 Agent 处理独立子任务。task 为任务描述，files 为相关文件，todos 为可选子任务清单（仅进子代理上下文声明，不做执行语义）。'
              'mode 可选 research（默认，只读调研返摘要）/plan（只出方案不落 diff，主循环审后执行）。子任务只读文件并返回摘要，不直接写文件。'
              '并行约束：同一批次的多个 spawn_subagent 会并发执行，但本项目子 Agent 无写权限、'
              '与主循环共享同一工作区读视图：不要让多个子任务同时依赖同一文件的实时写入结果，'
              '也不要让子任务假设其它并发子任务的输出已落盘；写文件一律由主循环串行执行。'
              '隔离说明：与 Claude Code worktree 隔离模式不同，本项目子 Agent 不做工作区隔离/分支隔离，'
              '仅靠只读约束避免 last-writer-wins 覆盖竞争，切勿用于并行写不同文件后人工合并的场景。',
          'parameters': {
            'type': 'object',
            'properties': {
              'task': {'type': 'string'},
              'files': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'todos': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              // R8-S1：mode 参数透出——此前文档写可选research/plan，
              // parameters 无 mode，模型传 mode 被 args 校验丢弃，plan 恒走 research。
              'mode': {
                'type': 'string',
                'enum': ['research', 'plan'],
              },
            },
            'required': ['task'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'write_file',
          'description': '新建或覆盖写文件。path 为相对路径，content 为完整内容。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'content': {'type': 'string'},
            },
            'required': ['path', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_file',
          'description': '精确文本替换。oldText 必须完全一致。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'oldText': {'type': 'string'},
              'newText': {'type': 'string'},
            },
            'required': ['path', 'oldText', 'newText'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'apply_patch',
          'description':
              '多文件原子补丁：一次改多个文件，要么全成功要么全回滚。'
              'patches 每项含 path 与以下一种操作：edit（oldText→newText，支持空白模糊匹配）、'
              'create（文件不存在时新建，传 newText）、delete（delete=true 删除文件）。'
              '优先用它替代多次 edit_file。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'patches': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'path': {'type': 'string'},
                    'oldText': {'type': 'string'},
                    'newText': {'type': 'string'},
                    'create': {'type': 'boolean'},
                    'delete': {'type': 'boolean'},
                  },
                  'required': ['path'],
                },
              },
            },
            'required': ['patches'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'todo_write',
          'description':
              '待办清单管理：长任务先拆步骤再动手。传 todos 全量替换当前清单，'
              '每项含 content 与 status（pending/in_progress/completed，可简写 pending/doing/done）；'
              '不传 todos 则返回当前清单。不读写文件，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'todos': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'content': {'type': 'string'},
                    'status': {'type': 'string'},
                    'id': {'type': 'string'},
                  },
                  'required': ['content'],
                },
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'fetch_url',
          'description':
              '内置网页抓取：传公网 http(s) url，返回截断后的文本（HTML 会去标签）。'
              '拒绝回环/私网/元数据；每次重定向都会再验。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'maxChars': {'type': 'integer'},
            },
            'required': ['url'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'lsp_hover',
          'description':
              '读当前光标处的 LSP hover 说明（类型/签名/文档注释），无需审批。'
              'path 为相对路径，line/character 为 0-based 位置（缺省用当前光标）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'line': {'type': 'integer'},
              'character': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'get_diagnostics',
          'description':
              '读取指定文件的当前诊断（错误/警告）。写完文件后用它自检，'
              'path 为相对路径（缺省则查本轮改动过的文件）。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        },
      },
      {
        // C1：仓库地图（目录树 + 符号表摘要），大仓冷启动先看全局再逐文件读。
        'type': 'function',
        'function': {
          'name': 'repo_map',
          'description':
              '返回仓库地图：目录树 + 符号表摘要（最多 300 文件）。只读，无需审批。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        // C1：语义检索（本地 TF-IDF，无第三方依赖），按自然语言找相关文件。
        'type': 'function',
        'function': {
          'name': 'semantic_search',
          'description':
              '按自然语言语义检索相关文件，返回路径 + 分数。只读，无需审批。query 必填，maxResults 可选。',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'maxResults': {'type': 'integer'},
            },
            'required': ['query'],
          },
        },
      },
      {
        // C2：LSP 跳转定义（已实现未暴露，现补齐只读工具）。
        'type': 'function',
        'function': {
          'name': 'lsp_definition',
          'description':
              '跳转符号定义，返回文件:行列表。path 为相对路径，line/character 为 0-based。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'line': {'type': 'integer'},
              'character': {'type': 'integer'},
            },
            'required': ['path', 'line', 'character'],
          },
        },
      },
      {
        // C2：LSP 查引用（已实现未暴露，现补齐只读工具）。
        'type': 'function',
        'function': {
          'name': 'lsp_references',
          'description':
              '查符号引用位置，返回文件:行列表。path 为相对路径，line/character 为 0-based。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'line': {'type': 'integer'},
              'character': {'type': 'integer'},
            },
            'required': ['path', 'line', 'character'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_file',
          'description': '删除工作区内文件。path 为相对路径。默认会询问用户。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'move_file',
          'description':
              '重命名/移动工作区内文件或目录。from 为源相对路径，to 为目标相对路径（可跨目录）。同名目标直接拒绝，不覆盖。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'from': {'type': 'string'},
              'to': {'type': 'string'},
            },
            'required': ['from', 'to'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'run_command',
          'description':
              '在工作区执行 shell 命令。白名单只读命令自动放行，其余弹窗确认，高危直接拒绝。'
              'background=true 时后台运行并返回任务 id（长任务如 flutter run/build 用它），'
              '再用 poll_task 查输出/kill_task 结束。',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
              'timeout': {'type': 'integer'},
              'background': {'type': 'boolean'},
            },
            'required': ['command'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'poll_task',
          'description':
              '轮询后台命令输出。taskId 为 run_command background 返回的 id；'
              'tail 行数可选；kill=true 时结束任务。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'taskId': {'type': 'string'},
              'tail': {'type': 'integer'},
              'kill': {'type': 'boolean'},
            },
            'required': ['taskId'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'load_skill',
          'description':
              '加载某个 Agent Skill 的完整说明（SKILL.md 正文与附属文件列表）。'
              '仅当任务与某 skill 的 description 明显相关，或用户用 /skill-name 点名时再调用。'
              '参数 name 为 skill 名称。',
          'parameters': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description': 'skill 名称（与目录名 / frontmatter name 一致）',
              },
            },
            'required': ['name'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'mcp_list_resources',
          'description':
              '列出已连接 MCP 服务器的 resources（serverId -> uri 列表）。只读，无需审批。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'mcp_read_resource',
          'description': '读取指定 MCP 服务器的 resource 文本。参数 serverId、uri。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'serverId': {'type': 'string'},
              'uri': {'type': 'string'},
            },
            'required': ['serverId', 'uri'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'mcp_list_prompts',
          'description': '列出已连接 MCP 服务器的 prompts（serverId -> 名称列表）。只读，无需审批。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'mcp_get_prompt',
          // C4：带参 prompt 补齐 arguments（JSON 对象），无参可不传。
          'description': '取指定 MCP 服务器 prompt 展开后的文本。参数 serverId、name，带参 prompt 可传 arguments 对象。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'serverId': {'type': 'string'},
              'name': {'type': 'string'},
              'arguments': {'type': 'object'},
            },
            'required': ['serverId', 'name'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'make_dir',
          'description': '新建目录（含父级递归）。path 为相对路径。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'copy_file',
          'description':
              '复制文件。from 为源相对路径，to 为目标相对路径（可跨目录）。同名目标直接拒绝，不覆盖。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'from': {'type': 'string'},
              'to': {'type': 'string'},
            },
            'required': ['from', 'to'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'set_executable',
          'description': '给文件置可执行位。path 为相对路径。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'read_media',
          'description':
              '媒体/二进制转文本描述：图片返回尺寸+大小+base64长度；PDF 提取可读文本前4KB；其它二进制给 file 判定。path 为相对路径。只读。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'terminal_create',
          'description': '创建常驻交互终端会话，返回 sessionId。Agent 模式可用，Plan 禁用。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'terminal_write',
          'description':
              '向常驻终端写入 stdin（命令+回车）。sessionId 为 terminal_create 返回的 id；cols/rows 可选调整尺寸。',
          'parameters': {
            'type': 'object',
            'properties': {
              'sessionId': {'type': 'string'},
              'input': {'type': 'string'},
              'cols': {'type': 'integer'},
              'rows': {'type': 'integer'},
            },
            'required': ['sessionId', 'input'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'terminal_poll',
          'description': '轮询常驻终端增量输出。sessionId 必填，tail 可选。只读。',
          'parameters': {
            'type': 'object',
            'properties': {
              'sessionId': {'type': 'string'},
              'tail': {'type': 'integer'},
            },
            'required': ['sessionId'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'terminal_kill',
          'description': '结束常驻终端会话。sessionId 必填。',
          'parameters': {
            'type': 'object',
            'properties': {
              'sessionId': {'type': 'string'},
            },
            'required': ['sessionId'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_open',
          'description':
              '打开网页（自研浏览器，内嵌优先、CDP 兜底）。传公网 http(s) url；'
              '私网/回环/元数据默认拒绝，本地调试需审批。需要审批。'
              'waitFrames=true 时等子帧 load 再返（已知含 iframe 时用）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'waitFrames': {'type': 'boolean'},
            },
            'required': ['url'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_read',
          'description':
              '读取当前页面 JS 渲染后文本。需先 browser_open。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'maxChars': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_snapshot',
          'description':
              '可交互快照：返回去噪后的可交互/语义节点（eN编号+tag+文本+selector），配合 browser_click/fill 定位。需先 browser_open。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'maxNodes': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_wait',
          'description':
              '显式等待：等 selector 可见或文本出现（navigate 后先 wait 再 snapshot/interact）。selector 与 text 至少其一，timeout 1~30s 默认10s。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'text': {'type': 'string'},
              'timeout': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          // R2-M6：独立 waitForNetworkIdle 工具（只读，复用 LoadWaiter
          // networkIdle 500ms 静默窗档，默认关口径的显式开启版）。
          'name': 'browser_wait_network_idle',
          'description':
              '等网络静默（networkIdle 500ms 静默窗，懒加载页用）。timeout 1~30s 默认10s。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'timeout': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_click',
          'description':
              '点击页面元素（先等可见、遮挡检查再原生点击）。selector 为 CSS 选择器（见 browser_snapshot）。force=true 跳过遮挡检查。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'force': {'type': 'boolean'},
            },
            'required': ['selector'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_fill',
          'description':
              '向输入框填文本（先等可见再设值并派发 input/change）。selector 为 CSS 选择器，text 为输入文本。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'text': {'type': 'string'},
            },
            'required': ['selector'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_eval',
          'description':
              '在当前页面执行 JS 并返回序列化结果。需要审批，js 上限 8000 字符。userGesture=true 时以用户手势执行（剪贴板等需手势 API 用）。contextId 指定帧执行上下文（iframe 内 eval 用）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'js': {'type': 'string'},
              'userGesture': {'type': 'boolean'},
              'contextId': {'type': 'integer'},
            },
            'required': ['js'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_console',
          'description':
              '读取页面控制台与 JS 错误（console/pageError/unhandledrejection）。'
              'errorsOnly=true 只看错误；urlContains 按页面 URL 子串过滤（多 iframe 时只看某页）。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'tail': {'type': 'integer'},
              'errorsOnly': {'type': 'boolean'},
              'urlContains': {'type': 'string'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_network',
          'description': '读取页面网络失败记录。urlContains 按 URL 子串过滤（多 iframe 时只看某页）。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'tail': {'type': 'integer'},
              'urlContains': {'type': 'string'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_screenshot',
          'description':
              '截取当前页面（需本机 Chrome/Edge，走 CDP）。返回截图路径与大小描述。只读，无需审批。fullPage=true 截全页（captureBeyondViewport），clip={x,y,width,height,scale} 截节点区域。',
          'parameters': {
            'type': 'object',
            'properties': {
              'fullPage': {'type': 'boolean'},
              'clip': {'type': 'object'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_reload',
          'description':
              '刷新当前页面并清当页 console/网络缓冲（改完本地页面后重验用）。有副作用（重载页面），走审批/串行。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        // R3-M8：后退（getNavigationHistory + navigateToHistoryEntry）。
        'type': 'function',
        'function': {
          'name': 'browser_go_back',
          'description': '后退到上一页（bfcache 恢复直接判已加载）。有副作用，走审批/串行。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        // R3-M9：停止加载（Page.stopLoading）。
        'type': 'function',
        'function': {
          'name': 'browser_stop_loading',
          'description': '停止当前页加载（无限加载页用，之后 load 等待立即收敛）。有副作用，走审批/串行。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_status',
          'description':
              '一句话自检：当前 url/targetId/通道/console 错误数/网络失败/chrome 可用性/渲染推流状态（ready/degraded/blocked），不抓页面内容。只读，无需审批。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_targets',
          'description': '列出当前浏览器可连接 page（id/url，只读枚举不建连接）。只读，无需审批。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_switch',
          'description': '切换到指定 targetId 的页面（精确命中，消失则报错不漂移；切后清缓冲等 load）。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'targetId': {'type': 'string'},
            },
            'required': ['targetId'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_geolocate',
          'description':
              '模拟定位（CDP Emulation.setGeolocationOverride，只读验证口径）：定位页验证用；无参即清除模拟。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'latitude': {'type': 'number'},
              'longitude': {'type': 'number'},
              'clear': {'type': 'boolean'},
            },
          },
        },
      },
      {
        // R4-11：视口模拟（Emulation.setDeviceMetricsOverride）。
        'type': 'function',
        'function': {
          'name': 'browser_viewport',
          'description':
              '模拟视口（390x844 等移动端布局验证用）；clear=true 清除模拟。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'width': {'type': 'integer'},
              'height': {'type': 'integer'},
              'mobile': {'type': 'boolean'},
              'deviceScaleFactor': {'type': 'number'},
              'clear': {'type': 'boolean'},
            },
          },
        },
      },
      {
        // R4-11：UA 覆盖（Emulation.setUserAgentOverride）。
        'type': 'function',
        'function': {
          'name': 'browser_user_agent',
          'description': '覆盖 UA 字符串。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'userAgent': {'type': 'string'},
            },
            'required': ['userAgent'],
          },
        },
      },
      {
        // R4-16：关闭页面（Target.closeTarget）。
        'type': 'function',
        'function': {
          'name': 'browser_close_target',
          'description': '关闭指定 targetId 的页面。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'targetId': {'type': 'string'},
            },
            'required': ['targetId'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_drag',
          'description': '拖拽元素从from到to。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'from': {'type': 'string'},
              'to': {'type': 'string'},
            },
            'required': ['from', 'to'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_select',
          'description': '下拉框选择值。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'value': {'type': 'string'},
            },
            'required': ['selector'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_upload',
          'description': '文件上传到file input。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'file': {'type': 'string'},
            },
            'required': ['selector', 'file'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_press',
          'description': '按键。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'key': {'type': 'string'},
            },
            'required': ['key'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_scroll',
          'description': '滚动到元素。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
            },
            'required': ['selector'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_hover',
          'description': '悬停元素（先等可见、遮挡检查）。force=true 跳过遮挡检查。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'force': {'type': 'boolean'},
            },
            'required': ['selector'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_dialog',
          'description': '处理JS对话框：accept=true接受（promptText填prompt），false关闭。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'accept': {'type': 'boolean'},
              'promptText': {'type': 'string'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_download_dir',
          'description': '设置下载接管目录。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'dir': {'type': 'string'},
            },
            'required': ['dir'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_frames',
          'description': '枚举页面frames（id/url）。只读，无需审批。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
    ];
  }

  /// 只读子集，供子 Agent 使用。从 [base] 按名过滤，保证参数与主循环一致。
  static List<Map<String, dynamic>> readOnly() {
    final all = base();
    return all
        .where((t) {
          final fn = t['function'] as Map<String, dynamic>?;
          final name = '${fn?['name'] ?? ''}';
          return readOnlyNames.contains(name);
        })
        .toList(growable: false);
  }

  static bool isReadOnly(String name) => readOnlyNames.contains(name);
}
