part of 'agent_tool_schemas.dart';

/// 执行与扩展类工具（命令/轮询/skill/MCP/目录拷贝权限/媒体/终端）
List<Map<String, dynamic>> _schemaGroupExec() => [
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
              '轮询后台任务输出。taskId 为 run_command background 返回的 id，或 spawn_subagent 传 async=true 时返回的异步子 Agent spawnId；'
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
    ];
