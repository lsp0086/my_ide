part of 'agent_tool_schemas.dart';

/// 只读与核心工具（读文件/检索/git/提问/子 Agent 派生）
List<Map<String, dynamic>> _schemaGroupCore() => [
      {
        'type': 'function',
        'function': {
          'name': 'read_file',
          'description': '读取文件内容。工作区内用相对路径；用户附件若给出相对路径可直接读。工作区外用绝对路径（需审批）。传 anchor（0-based 行号）时按缩进锚定返回包含该行的整个函数/类块，适合查看栈追踪对应的完整实现。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'limit': {'type': 'integer'},
              'offset': {'type': 'integer'},
              'anchor': {'type': 'integer'},
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
              'mode 可选 research（默认，只读调研返摘要）/plan（只出方案不落 diff，主循环审后执行）。'
              'model 可选：子 Agent 使用的模型 id（须为设置中已启用模型的 id），适合给机械子任务配弱模型、给关键调研配强模型；未传沿用当前模型。'
              'role 可选：子 Agent 角色模板名（工作区 .my_ide/agents/<role>.md）。命中模板即以模板的角色系统提示附加段+工具白名单派生，'
              '模板未命中则本工具返回可用角色清单；模板 tools 白名单与当前 Skill 约束求交生效，写工具即便声明也仅由主循环走审批执行（子 Agent 无写通道）。'
              '子任务只读文件并返回摘要，不直接写文件。'
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
              // E5-MODEL：子任务可指定模型（弱/强模型），Runner 侧按已启用模型解析。
              'model': {
                'type': 'string',
                'description': '子 Agent 模型 id（须为设置中已启用模型），未传沿用当前模型',
              },
              // G-R2-9：角色模板名（.my_ide/agents/<role>.md）。命中即以模板
              // 提示+工具白名单派生；未命中返回可用角色清单。
              'role': {
                'type': 'string',
                'description':
                    '子 Agent 角色模板名（工作区 .my_ide/agents/ 下的 *.md），未命中时返回可用角色清单',
              },
              // T36：异步派生——传 async=true 立即返回 spawnId 不阻塞主流，
              // 后续用 poll_task 按 id 取回结果。对标 Claude Code 后台子 Agent。
              'async': {
                'type': 'boolean',
                'description':
                    'true=异步派生：立即返回 spawnId，主流继续执行；结果用 poll_task 按 id 取回',
              },
            },
            'required': ['task'],
          },
        },
      },
    ];
