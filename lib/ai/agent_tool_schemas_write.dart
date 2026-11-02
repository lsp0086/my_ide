part of 'agent_tool_schemas.dart';

/// 写与补丁类工具（写/编辑/补丁/待办/抓取/LSP/语义索引/删改）
List<Map<String, dynamic>> _schemaGroupWrite() => [
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
    ];
