part of 'agent_tool_schemas.dart';

/// 浏览器基础工具（打开/读取/快照/等待/点击/填写/求值/控制台/网络/截图/导航/target）
List<Map<String, dynamic>> _schemaGroupBrowser() => [
      {
        'type': 'function',
        'function': {
          'name': 'browser_open',
          'description':
              '打开网页（自研浏览器，内嵌优先、CDP 兜底）。传公网 http(s) url；'
              '私网/回环/元数据默认拒绝，本地调试需审批。需要审批。'
              'waitFrames=true 时等子帧 load 再返（已知含 iframe 时用）。'
              'waitUntil 可选 load（默认）/commit/domcontentloaded/networkidle（慢资源页秒级返回）。'
              'certBypass=true 显式开启证书旁路（自签/过期证书页可打开，记审计，默认关）。'
              'newTab=true 时另开一个新标签页（Target.createTarget）而不在当前页导航；'
              'newContext=true（配 newTab）建独立浏览器上下文（cookie/登录态隔离）。'
              '随后用 browser_switch targetId=... 切入（多标签并行调研/对比时用）。'
              '带 basicAuthUser/basicAuthPassword 时对该 origin 的 401 挑战自动注入 Basic 凭据。'
              'initScript 为初始化脚本（≤8000 字符，隔离 world 注入，每个新文档导航前执行、跨导航存活）；'
              '页面经 window.<bindingName>(payload)（默认 __agentReport）调用后回报回流 console（untrusted 围栏）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'waitFrames': {'type': 'boolean'},
              'waitUntil': {
                'type': 'string',
                'enum': ['load', 'commit', 'domcontentloaded', 'networkidle'],
                'description': '导航等待档位，默认 load',
              },
              'newTab': {
                'type': 'boolean',
                'description': '另开新标签页（不在当前页导航）',
              },
              'newContext': {
                'type': 'boolean',
                'description': '配 newTab：独立浏览器上下文（登录态隔离）',
              },
              'certBypass': {
                'type': 'boolean',
                'description': '证书旁路开关（默认关，开启记审计）',
              },
              'initScript': {
                'type': 'string',
                'description':
                    '初始化脚本（≤8000 字符）：Page.addScriptToEvaluateOnNewDocument 隔离 world 注入，每个新文档导航前执行、跨导航存活。页面可经 window.<bindingName>(payload) 向 Agent 回报（回流 console）',
              },
              'bindingName': {
                'type': 'string',
                'description':
                    '页面→Agent 回报通道名（合法 JS 标识符，≤64 字符，默认 __agentReport）：Runtime.addBinding 注册，页面调用 window.<name>(payload) 后消息归因进 console（untrusted 围栏）',
              },
              'basicAuthUser': {'type': 'string'},
              'basicAuthPassword': {'type': 'string'},
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
              '显式等待：等 selector 可见、文本出现、waitValue(selector+waitValue) 元素值/文本等于期望（自动轮询重试，Playwright toHaveValue 口径），或 condition=networkIdle 网络静默（lifecycle 事件驱动，超时附在途请求归因）。selector/text/waitValue/condition 至少其一，timeout 1~30s 默认10s。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'text': {'type': 'string'},
              'waitValue': {'type': 'string'},
              'condition': {
                'type': 'string',
                'description': '可选等待条件，当前支持 networkIdle',
              },
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
          // C8：网页转 PDF（读侧存档，printToPDF）。
          'name': 'browser_pdf',
          'description':
              '网页转 PDF 存档（Page.printToPDF，无头通道）。pageRanges 格式如 1-3,5（start<=end），scale 0.1~2.0，landscape 横向。落盘 .my_ide/artifacts/ 返回路径。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'pageRanges': {'type': 'string'},
              'scale': {'type': 'number'},
              'landscape': {'type': 'boolean'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_click',
          'description':
              '点击页面元素（先等可见、遮挡检查再原生点击）。定位二选一：selector 为 CSS 选择器，或 ref 为 browser_snapshot 输出的 eN 编号（DOM 变更后旧 ref 明确报 stale 需重取快照，优先用 ref 免手写选择器）。force=true 跳过遮挡检查。点击触发原生文件选择器（自定义上传按钮）时传 fileChooserFiles（工作区内相对路径数组，≤10 个）自动回填。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'ref': {
                'type': 'string',
                'description': 'browser_snapshot 输出的 eN 编号（与 selector 二选一）',
              },
              'force': {'type': 'boolean'},
              'fileChooserFiles': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_fill',
          'description':
              '向输入框填文本（先等可见再设值并派发 input/change）。定位二选一：selector 为 CSS 选择器，或 ref 为 browser_snapshot 输出的 eN 编号（DOM 变更后旧 ref 明确报 stale）。text 为输入文本。slowly=true 时逐字符 dispatchKeyEvent 输入（触发只监听键盘事件的输入框的 per-char 回调，如验证码/掩码输入），默认 false 走整段快口径。需要审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'selector': {'type': 'string'},
              'ref': {
                'type': 'string',
                'description': 'browser_snapshot 输出的 eN 编号（与 selector 二选一）',
              },
              'text': {'type': 'string'},
              'slowly': {'type': 'boolean'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_eval',
          'description':
              '在当前页面执行 JS 并返回序列化结果。需要审批，js 上限 8000 字符。userGesture=true 时以用户手势执行（剪贴板等需手势 API 用）。contextId 指定帧执行上下文（iframe 内 eval 用）。read_only=true 时只读模式（Runtime.evaluate throwOnSideEffect）：带副作用的表达式被拒、纯读取返回，blocked/untrusted 页无风险探查用。',
          'parameters': {
            'type': 'object',
            'properties': {
              'js': {'type': 'string'},
              'userGesture': {'type': 'boolean'},
              'contextId': {'type': 'integer'},
              'read_only': {
                'type': 'boolean',
                'description': '只读模式：副作用表达式被拒（throwOnSideEffect），纯读取返回',
              },
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
              'errorsOnly=true 只看错误；level=error/warning/info 按级别过滤；'
              'urlContains 按页面 URL 子串过滤（多 iframe 时只看某页）；'
              'limit(1~500)/offset 分页切片（新→旧，返回体注明第 N~M 条/共 T 条），不传保持默认行为。只读，无需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'tail': {'type': 'integer'},
              'errorsOnly': {'type': 'boolean'},
              'urlContains': {'type': 'string'},
              'limit': {'type': 'integer', 'description': '条数 1~500'},
              'offset': {'type': 'integer', 'description': '跳过最新 N 条'},
              'level': {
                'type': 'string',
                'enum': ['error', 'warning', 'info'],
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_network',
          'description':
              '读取页面网络失败记录。urlContains 按 URL 子串过滤（多 iframe 时只看某页）；'
              'type 按资源类型过滤（document/script/xhr/fetch/image/websocket 等，大小写不敏感）；'
              'limit(1~500)/offset 分页切片（新→旧，返回体注明第 N~M 条/共 T 条），不传保持默认行为。'
              'all=true 改读全量请求表（含成功请求，requestId/url/status/type），'
              '并可加 status 过滤（success=2xx/failure=4xx/5xx/pending=无响应/200 等状态码）。'
              "action='body' 按请求查响应体（requestId 或 url 子串定位，512KB 预算，超大返回'过大已跳过'）。只读，无需审批。",
          'parameters': {
            'type': 'object',
            'properties': {
              'tail': {'type': 'integer'},
              'urlContains': {'type': 'string'},
              'all': {
                'type': 'boolean',
                'description': 'true=读全量请求表（含成功请求），默认 false 只读失败记录',
              },
              'action': {
                'type': 'string',
                'enum': ['body'],
                'description': "action=body：按 requestId/url 查响应体",
              },
              'requestId': {
                'type': 'string',
                'description': 'action=body 时优先使用的请求 id',
              },
              'url': {
                'type': 'string',
                'description': 'action=body 时按 URL 子串取最近一条命中请求',
              },
              'status': {
                'type': 'string',
                'description': '状态过滤（仅 all=true）：success/failure/pending/200',
              },
              'limit': {'type': 'integer', 'description': '条数 1~500'},
              'offset': {'type': 'integer', 'description': '跳过最新 N 条'},
              'type': {
                'type': 'string',
                'description': '资源类型，如 document/script/xhr/fetch/image/websocket',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_screenshot',
          'description':
              '截取当前页面（需本机 Chrome/Edge，走 CDP）。返回截图路径与大小描述。只读，无需审批。fullPage=true 截全页（captureBeyondViewport），clip={x,y,width,height,scale} 截节点区域。format=png/jpeg/webp（默认 jpeg），quality 1~100（仅 jpeg/webp），optimizeForSpeed=true 动画/大页秒级返回（质量略降，webp 恒带）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'fullPage': {'type': 'boolean'},
              'clip': {'type': 'object'},
              'format': {
                'type': 'string',
                'enum': ['jpeg', 'png', 'webp'],
              },
              'quality': {'type': 'integer', 'description': '压缩质量 1~100（仅 jpeg/webp）'},
              'optimizeForSpeed': {'type': 'boolean'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'browser_reload',
          'description':
              '刷新当前页面并清当页 console/网络缓冲（改完本地页面后重验用）。有副作用（重载页面），走审批/串行。'
              'initScript/bindingName 可选（与 browser_open 同口径）：新脚本随本次 reload 产出的新文档执行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'initScript': {
                'type': 'string',
                'description': '初始化脚本（≤8000 字符），随 reload 新文档执行',
              },
              'bindingName': {
                'type': 'string',
                'description': '页面→Agent 回报通道名（合法 JS 标识符，默认 __agentReport）',
              },
            },
          },
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
          'parameters': {'type': 'object', 'properties': {
              // G-B15：缺省 page；all=全部；worker/service_worker 只读枚举。
              'type': {'type': 'string'},
            }},
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
              '模拟视口（390x844 等移动端布局验证用）；clear=true 清除模拟。'
              'touch=true 开启触屏模拟（hasTouch/hover 行为，mobile=true 时默认开启）；'
              'maxTouchPoints 1~10（默认 5）。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'width': {'type': 'integer'},
              'height': {'type': 'integer'},
              'mobile': {'type': 'boolean'},
              'deviceScaleFactor': {'type': 'number'},
              'touch': {
                'type': 'boolean',
                'description': '开启触屏模拟（默认 mobile=true 时开启）',
              },
              'maxTouchPoints': {
                'type': 'integer',
                'description': '最大触点数 1~10（默认 5）',
              },
              'clear': {'type': 'boolean'},
            },
          },
        },
      },
      {
        // G2-5：CPU/网络节流模拟（Emulation.setCPUThrottlingRate /
        // Network.emulateNetworkConditions，来源 chrome-devtools-mcp）。
        'type': 'function',
        'function': {
          'name': 'browser_emulate',
          'description':
              '模拟 CPU/网络/断网/时区/语言/设备预设/滚动条与媒体特性（慢设备/弱网/离线/跨时区/移动端页面行为验证用）。'
              'kind=cpu 时 rate 为降速倍数 1~20（1=不节流，必填）；'
              'kind=network 时 downloadKbps/uploadKbps/latencyMs 可选（KB/s 与毫秒，须非负）；'
              'kind=offline 时 offline=true 完全断网（默认恢复在线，或 clear=true 恢复）；'
              'kind=timezone 时 timezoneId 为 IANA 时区（如 Asia/Shanghai，clear=true 恢复真实）；'
              'kind=locale 时 locale 为语言标签（如 zh-CN，clear=true 恢复真实）；'
              'kind=device 时 device 为内置预设名（iphone13/iphone15/ipad/pixel7/galaxy_s23/desktop_chrome，'
              'UA+触屏+DPR+viewport 整组生效；userAgent/width/height/deviceScaleFactor/touch 显式传入则覆盖对应项；'
              'clear=true 整组还原视口/触屏/UA）；'
              'kind=hideScrollbars 时 hideScrollbars=true 隐藏滚动条（false/clear=true 恢复显示）；'
              'kind=reducedMotion 时 reducedMotion=true 模拟 prefers-reduced-motion: reduce（false/clear=true 恢复）；'
              'kind=forcedColors 时 forcedColors=true 模拟 forced-colors: active（false/clear=true 恢复）；'
              'network 全部缺省或 clear=true 即清除模拟恢复默认；kind=cpu 且 clear=true 恢复 rate=1。有副作用，走审批/串行。',
          'parameters': {
            'type': 'object',
            'properties': {
              'kind': {
                'type': 'string',
                'enum': [
                  'cpu',
                  'network',
                  'offline',
                  'timezone',
                  'locale',
                  'device',
                  'hideScrollbars',
                  'reducedMotion',
                  'forcedColors',
                ],
              },
              'rate': {'type': 'number', 'description': 'CPU 降速倍数 1~20'},
              'downloadKbps': {'type': 'number', 'description': '下载 KB/s'},
              'uploadKbps': {'type': 'number', 'description': '上传 KB/s'},
              'latencyMs': {'type': 'number', 'description': '附加延迟毫秒'},
              'offline': {
                'type': 'boolean',
                'description': 'kind=offline：true=完全断网，false=恢复在线',
              },
              'timezoneId': {
                'type': 'string',
                'description': 'kind=timezone：IANA 时区，如 Asia/Shanghai',
              },
              'locale': {
                'type': 'string',
                'description': 'kind=locale：语言标签，如 zh-CN / en-US',
              },
              // G9：设备预设与覆盖项（device 整组应用，单参数覆盖对应项）。
              'device': {
                'type': 'string',
                'description':
                    'kind=device：预设名 iphone13/iphone15/ipad/pixel7/galaxy_s23/desktop_chrome',
              },
              'userAgent': {
                'type': 'string',
                'description': 'kind=device：覆盖预设 UA',
              },
              'width': {'type': 'integer', 'description': 'kind=device：覆盖预设视口宽'},
              'height': {'type': 'integer', 'description': 'kind=device：覆盖预设视口高'},
              'deviceScaleFactor': {
                'type': 'number',
                'description': 'kind=device：覆盖预设 DPR',
              },
              'touch': {
                'type': 'boolean',
                'description': 'kind=device：覆盖预设触屏开关',
              },
              // GB7：滚动条与媒体特性模拟。
              'hideScrollbars': {
                'type': 'boolean',
                'description': 'kind=hideScrollbars：true=隐藏滚动条，false=恢复显示',
              },
              'reducedMotion': {
                'type': 'boolean',
                'description':
                    'kind=reducedMotion：true=模拟 prefers-reduced-motion: reduce，false=恢复',
              },
              'forcedColors': {
                'type': 'boolean',
                'description':
                    'kind=forcedColors：true=模拟 forced-colors: active，false=恢复',
              },
              'clear': {'type': 'boolean'},
            },
            'required': ['kind'],
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
    ];
