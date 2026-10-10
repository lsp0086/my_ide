import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../browser/browser_service.dart';
import '../theme/app_colors.dart';

/// Agent 唤起的页面标签页（Trae 式"打开即看"）。
///
/// 最小体积渲染选型（零依赖口径）：不引 webview/CEF（数百 MB 二进制或需
/// 三端原生胶水），复用 Agent 已有的 headless Chrome CDP 会话，经
/// `Page.startScreencast` 把渲染帧以 JPEG 流进本视图。页面只能由 Agent
/// 经 browser_open 唤起；本视图是只读观看窗，交互（点击/输入/eval/刷新）
/// 一律走 Agent 的 browser_* 工具。
///
/// 来源：CDP Page 域 screencast 协议
/// https://chromedevtools.github.io/devtools-protocol/tot/Page/ ；
/// agent-browser 录制/串流同协议 https://agent-browser.dev/changelog 。
class BrowserPageView extends StatefulWidget {
  const BrowserPageView({super.key, required this.initialUrl});

  /// 页面标签页创建时的 URL；后续以 Agent 打开事件的 URL 为准。
  final String initialUrl;

  @override
  State<BrowserPageView> createState() => _BrowserPageViewState();
}

class _BrowserPageViewState extends State<BrowserPageView> {
  StreamSubscription<BrowserPageEvent>? _openSub;
  StreamSubscription<String>? _frameSub;
  BrowserService? _service;
  // R1-BR3：绑定世代——同service二次open时旧帧订阅cancel未await，
  // 旧帧在途仍进_frame闪一下。回调凭世代丢弃旧绑定帧。
  int _bindGen = 0;
  String _url = '';
  String? _frame;
  // R3-B2：帧节流——此前逐帧setState+build内base64Decode跑UI isolate，
  // 30fps即卡顿。现100ms节流+丢旧帧（只保最新），loading占位立即清。
  DateTime _lastFrameAt = DateTime.fromMicrosecondsSinceEpoch(0);
  String? _pendingFrame;
  // 轮次1：末帧冲刷定时器——节流窗到期后渲染滞留的 pending 帧。
  Timer? _pendingFlushTimer;

  @override
  void initState() {
    super.initState();
    _url = widget.initialUrl;
    // 关键时序：页面标签页由 pageOpened 事件唤起，而本视图在事件之后才
    // 创建（broadcast 不回放）——必须先吃 lastOpened 立即绑定当前 service，
    // 否则首开的帧流永远等不到（典型流程里只有一次 browser_open）。
    final last = BrowserService.lastOpened;
    if (last != null) {
      _onPageOpened(last);
    }
    _openSub = BrowserService.pageOpened.stream.listen(_onPageOpened);
  }

  void _onPageOpened(BrowserPageEvent e) {
    if (!mounted) return;
    final rebind = !identical(e.service, _service);
    // R10R1：同 service 二次 open 同样清空旧帧，否则新页 load 期间仍显示
    // 旧页截图误导。复现：browser_open A 后再 open B，B load 期间仍见 A。
    setState(() {
      _url = e.url;
      if (!rebind) _frame = null;
    });
    if (rebind) {
      _service = e.service;
      _frame = null;
      // R1-BR3：换绑先占新世代再取消旧订阅——旧帧在途回调凭旧世代丢弃，
      // 不再闪一下旧页。
      final gen = ++_bindGen;
      final oldSub = _frameSub;
      _frameSub = null;
      try {
        oldSub?.cancel();
      } catch (_) {}
      _frameSub = e.service.screencastFrames.listen((data) {
        if (!mounted || gen != _bindGen) return;
        // B3-03：loading:占位非 base64，直接解码即进 errorBuilder闪烁；
        // 此处收占位即清帧回等待态，与真帧可区分。
        if (data.startsWith('loading:')) {
          _pendingFlushTimer?.cancel();
          _pendingFlushTimer = null;
          _pendingFrame = null;
          setState(() => _frame = null);
          return;
        }
        // R3-B2：100ms节流+丢旧帧——高频帧只保最新pending，不逐帧setState。
        _pendingFrame = data;
        final now = DateTime.now();
        final elapsed = now.difference(_lastFrameAt);
        if (elapsed < const Duration(milliseconds: 100)) {
          // 轮次1：末帧滞留防线——突发帧的最后一帧此前滞留 _pendingFrame
          // 无定时冲刷，页面停止变化后 UI 永远停在倒数第二帧。现补
          // 冲刷定时器，节流窗到期后渲染 pending 帧。
          _pendingFlushTimer?.cancel();
          _pendingFlushTimer = Timer(
            const Duration(milliseconds: 100) - elapsed,
            () {
              _pendingFlushTimer = null;
              if (!mounted || gen != _bindGen) return;
              final latest = _pendingFrame;
              if (latest == null) return;
              _pendingFrame = null;
              _lastFrameAt = DateTime.now();
              setState(() => _frame = latest);
            },
          );
          return;
        }
        _pendingFlushTimer?.cancel();
        _lastFrameAt = now;
        final latest = _pendingFrame;
        _pendingFrame = null;
        if (latest != null) setState(() => _frame = latest);
      });
    }
    // 幂等：同 client 已挂流则早退；此前启动失败（如 Chrome 未起）时
    // 借后续 open 事件自动重试，不需要额外定时器。
    unawaited(e.service.startScreencast());
  }

  @override
  void dispose() {
    _openSub?.cancel();
    _frameSub?.cancel();
    _pendingFlushTimer?.cancel();
    _pendingFlushTimer = null;
    unawaited(_service?.stopScreencast());
    _service = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      color: colors.panelElevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: colors.panel,
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.public_rounded,
                  size: 15,
                  color: colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _url.isEmpty ? '等待 Agent 打开页面' : _url,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.panelHover,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: colors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 12,
                        color: colors.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Agent 控制',
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _frame != null
                ? InteractiveViewer(
                    minScale: 0.4,
                    maxScale: 6,
                    child: Image.memory(
                      base64Decode(_frame!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) {
                        return _WaitHint(colors: colors, url: _url);
                      },
                    ),
                  )
                : _WaitHint(colors: colors, url: _url),
          ),
        ],
      ),
    );
  }
}

class _WaitHint extends StatelessWidget {
  const _WaitHint({required this.colors, required this.url});

  final IdeColors colors;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            '正在通过 Agent 的浏览器渲染页面',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            url.isEmpty
                ? '让 Agent 调用 browser_open 打开一个页面'
                : '让 Agent 对 $url 执行操作，帧流将自动刷新',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
