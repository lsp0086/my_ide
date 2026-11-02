part of 'agent_tool_schemas.dart';

/// computer-use 与模式切换（screenshot/click/move/drag/scroll/press/type/open/key/wait/switch_mode）
List<Map<String, dynamic>> _schemaGroupComputer() => [
      {
        'type': 'function',
        'function': {
          'name': 'computer_screenshot',
          'description':
              '本机截图（macOS screencapture / Linux需gnome-screenshot或import或scrot / Windows PowerShell），落盘 tmp/myide-computer-shots（20张轮转）。返回截图路径。可选 region 区域截图（x/y/width/height 屏幕像素，四者须同时给）。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
              'y': {'type': 'integer'},
              'width': {'type': 'integer'},
              'height': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_click',
          'description': '本机鼠标点击。x/y 为屏幕像素（0~10000），button=left/right/middle，times=1/2/3 单击/双击/三击。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
              'y': {'type': 'integer'},
              'button': {'type': 'string'},
              'times': {'type': 'integer'},
            },
            'required': ['x', 'y'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_move',
          'description': '本机鼠标移动到 x/y 屏幕像素。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
              'y': {'type': 'integer'},
            },
            'required': ['x', 'y'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_drag',
          'description': '本机鼠标拖拽 (x1,y1)→(x2,y2) 屏幕像素。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'x1': {'type': 'integer'},
              'y1': {'type': 'integer'},
              'x2': {'type': 'integer'},
              'y2': {'type': 'integer'},
            },
            'required': ['x1', 'y1', 'x2', 'y2'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_scroll',
          'description': '本机滚轮。direction=up/down/left/right，amount=1~20 默认3；x/y 可选指定位置。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'direction': {'type': 'string'},
              'amount': {'type': 'integer'},
              'x': {'type': 'integer'},
              'y': {'type': 'integer'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_press',
          'description': '本机按键（Enter/Escape/Tab/F5 等，≤64字符）。需要审批（approveComputer，默认 ask）。',
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
          'name': 'computer_type',
          'description': '本机键入文本（1~4000字符，macOS经剪贴板中转会覆盖剪贴板）。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_open',
          'description': '本机打开路径或 http(s) URL（open/xdg-open/start）。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'target': {'type': 'string'},
            },
            'required': ['target'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_key',
          'description': '本机组合键/修饰键按住释放分离。keys 支持组合（ctrl+shift+a；修饰键 cmd/ctrl/alt/shift/fn）；action=tap（默认，触发组合键）/down（按住不释放）/up（释放）/hold（按住 holdMs 毫秒后释放）。用于 ctrl+click 多选、shift+click 连选、长按菜单。需要审批（approveComputer，默认 ask）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'keys': {'type': 'string'},
              'action': {'type': 'string'},
              'holdMs': {'type': 'integer'},
            },
            'required': ['keys'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'computer_wait',
          'description': '本机操作后等待渲染落定（100~30000ms，默认 1000）——SPA 懒加载/动画期间替代盲截图猜时机，等待后再观测。',
          'parameters': {
            'type': 'object',
            'properties': {
              'ms': {'type': 'integer'},
            },
          },
        },
      },
      {
        // T37：模型自主切换模式（对标 Cline switch_mode / Roo Code mode switch）。
        // 仅 agent↔plan 互切，禁止自行进 chat；切换事件落 app.log。
        'type': 'function',
        'function': {
          'name': 'switch_mode',
          'description':
              '在本轮内切换 Agent 模式。plan→agent：只读调研结论已足够、需要写文件或执行命令时用；'
              'agent→plan：改动风险升高、想先只读核对现状时用。'
              '不支持切到 chat。切换后同轮后续工具按新模式门禁生效。',
          'parameters': {
            'type': 'object',
            'properties': {
              'mode': {
                'type': 'string',
                'enum': ['agent', 'plan'],
                'description': '目标模式',
              },
              'reason': {
                'type': 'string',
                'description': '切换原因（≤200 字，落审计日志）',
              },
            },
            'required': ['mode'],
          },
        },
      },
    ];
