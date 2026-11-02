part of 'agent_tool_schemas.dart';

/// 浏览器交互工具（拖拽/选择/上传/按键/滚动/悬停/对话框/下载/帧/指标/trace/mhtml/路由/cookie/权限）
List<Map<String, dynamic>> _schemaGroupBrowserInteract() => [
      {
        'type': 'function',
        'function': {
          'name': 'browser_drag',
          'description':
              '拖拽元素从from到to（两端均可传 CSS 选择器或 browser_snapshot 的 eN 编号 fromRef/toRef，DOM 变更后旧 ref 明确报 stale）。可选 dataTransfer（对象，键为 MIME 类型如 "text/plain"，值为文本）随拖拽链下发，页面 dragover/drop 读 dataTransfer 才放行的场景必带。draggable 目标自动走 HTML5 原生拖放（Input.dispatchDragEvent 结构化 DragData），非 draggable 回退鼠标合成。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'from': {'type': 'string'},
              'to': {'type': 'string'},
              'fromRef': {
                'type': 'string',
                'description': '起点 eN 编号（与 from 二选一）',
              },
              'toRef': {
                'type': 'string',
                'description': '终点 eN 编号（与 to 二选一）',
              },
              'dataTransfer': {
                'description': 'HTML5 dataTransfer 数据项：{"MIME类型": "文本"}，最多 16 项',
                'type': 'object',
                'additionalProperties': {'type': 'string'},
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_select',
          'description':
              '下拉框选择值。定位二选一：selector 为 CSS 选择器，或 ref 为 browser_snapshot 的 eN 编号。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'ref': {
                'type': 'string',
                'description': 'browser_snapshot 输出的 eN 编号（与 selector 二选一）',
              },
              'value': {'type': 'string'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_upload',
          'description':
              '文件上传到file input。定位二选一：selector 为 CSS 选择器，或 ref 为 browser_snapshot 的 eN 编号；file 为工作区内相对路径。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'ref': {
                'type': 'string',
                'description': 'browser_snapshot 输出的 eN 编号（与 selector 二选一）',
              },
              'file': {'type': 'string'},
            },
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
          'description':
              '滚动到元素。定位二选一：selector 为 CSS 选择器，或 ref 为 browser_snapshot 的 eN 编号。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'ref': {
                'type': 'string',
                'description': 'browser_snapshot 输出的 eN 编号（与 selector 二选一）',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_hover',
          'description':
              '悬停元素（先等可见、遮挡检查）。定位二选一：selector 为 CSS 选择器，或 ref 为 browser_snapshot 的 eN 编号。force=true 跳过遮挡检查。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'ref': {
                'type': 'string',
                'description': 'browser_snapshot 输出的 eN 编号（与 selector 二选一）',
              },
              'force': {'type': 'boolean'},
            },
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
      {
        'type': 'function',
        'function': {
          'name': 'browser_metrics',
          'description':
              '查询当前页性能指标（CDP Performance.getMetrics：LayoutDuration/RecalcStyleDuration/ScriptDuration/JSHeapUsedSize/Nodes/LayoutCount 等）。只读，无需审批。对标 chrome-devtools-mcp performance_analyze_insight。',
          'parameters': {
            'type': 'object',
            'properties': {
              // G-B14：insight=true 走 trace 洞察层（LCP/FCP/长任务 TopN）。
              'insight': {'type': 'boolean'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_trace',
          'description':
              '采集页面性能 trace（CDP Tracing.start/end）。action=start 起采集，action=end 结束并落盘 .my_ide/artifacts/。可选 categories（数组或逗号分隔字符串，如 "devtools.timeline,input"）。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['start', 'end'],
                'description': 'start=开始采集；end=结束并落盘',
              },
              'categories': {
                'description': 'trace 类别（可选）：数组或逗号分隔字符串',
                'oneOf': [
                  {'type': 'array', 'items': {'type': 'string'}},
                  {'type': 'string'},
                ],
              },
            },
            'required': ['action'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_mhtml',
          'description':
              '把当前页存为 MHTML 单文件存档（CDP Page.captureSnapshot，含子资源），落盘 .my_ide/artifacts/ 并返回路径。只读，无需审批。对标 Chrome DevTools"另存为 MHTML"。',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_route',
          'description':
              '请求路由/改写（Fetch 域）。action=add/remove/list/clear。'
              'add 参数：pattern（URL 匹配："~regex:" 前缀=正则；含 "*"=glob；否则子串；"*" 结尾=前缀通配）、'
              'ruleAction=fulfill（mock 响应，配 status/body 或 bodyBase64（二进制 base64）/headers）/abort（阻断，可配 errorReason）/headers（放行并追加请求头）。'
              'list 输出每条命中计数。'
              '用于屏蔽分析脚本、mock 接口（含二进制）、改请求头等排障。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['add', 'remove', 'list', 'clear'],
              },
              'pattern': {'type': 'string'},
              'ruleAction': {
                'type': 'string',
                'enum': ['fulfill', 'abort', 'headers'],
              },
              'status': {'type': 'integer'},
              'body': {'type': 'string'},
              'bodyBase64': {
                'type': 'string',
                'description': '二进制 mock 响应体（base64，优先于 body）',
              },
              'headers': {'type': 'object'},
              'errorReason': {'type': 'string'},
              'id': {'type': 'string'},
            },
            'required': ['action'],
          },
        },
      },
      {
        // G-B4：cookie/登录态管理（get/set/clear，输出脱敏，set/clear 走写通道审批）。
        'type': 'function',
        'function': {
          'name': 'browser_cookies',
          'description':
              '浏览器 cookie/登录态管理。action=get（读当前 cookie，可选 url 过滤；'
              '敏感值经脱敏后输出）/set（写入：name+value 必填，url 或 domain 之一限定 origin，'
              '可选 path/secure/httpOnly/sameSite/expires）/clear（name 省略=清空全部，'
              '带 name=按 url/domain/path 删除单条）。set/clear 有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['get', 'set', 'clear'],
              },
              'url': {'type': 'string', 'description': 'origin 限定（get/set/clear）'},
              'name': {'type': 'string', 'description': 'cookie 名（set 必填；clear 可选）'},
              'value': {'type': 'string', 'description': 'cookie 值（set 必填）'},
              'domain': {'type': 'string'},
              'path': {'type': 'string'},
              'secure': {'type': 'boolean'},
              'httpOnly': {'type': 'boolean'},
              'sameSite': {
                'type': 'string',
                'enum': ['Strict', 'Lax', 'None'],
              },
              'expires': {
                'type': 'number',
                'description': '过期时间（UNIX 秒；省略=会话 cookie）',
              },
            },
            'required': ['action'],
          },
        },
      },
      {
        // G-B11：运行时权限管理（Browser.grantPermissions/resetPermissions）。
        'type': 'function',
        'function': {
          'name': 'browser_permissions',
          'description':
              '浏览器运行时权限管理（origin 限定）。action=grant（permissions 数组，'
              '白名单：geolocation/notifications/camera/microphone/clipboardReadWrite/'
              'durableStorage/backgroundSync/sensors 等）/clear（清除，origin 省略=默认源）。'
              'grant 后页面 API（如 Notification.requestPermission）可用。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['grant', 'clear'],
              },
              'permissions': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '权限名（grant 必填，白名单见描述）',
              },
              'origin': {
                'type': 'string',
                'description': '源限定（如 https://a.test；省略=默认源）',
              },
            },
            'required': ['action'],
          },
        },
      },
    ];
