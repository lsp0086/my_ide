part of 'chrome_cdp.dart';

/// 页内 JS 求值（Runtime.evaluate + 异常/超时/序列化降级处理）。
extension CdpClientEvaluate on CdpClient {
  Future<Map<String, dynamic>> evaluate(
    String js, {
    bool awaitPromise = true,
    Duration? cdpTimeout,
    int? contextId,
    String? uniqueContextId,
    bool userGesture = false,
    // GB8：只读求值——Runtime.evaluate 带 throwOnSideEffect:true（CDP 文档
    // 字段名已核对：https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate
    // 参数即 `throwOnSideEffect`，experimental）。副作用无法排除时 V8 以
    // "EvalError: Possible side-effect in debug-evaluate" 拒绝执行，上层
    // 映射为可读文案。默认 false 不带该参数（既有副作用 eval 不回归）。
    bool throwOnSideEffect = false,
  }) async {
    // R8-A5/B2 js有界8k：MB级expression此前直发CDP致包膨胀。
    // 与上层evaluate 8000门禁同口径，底层同样拒发（直调evaluate不经上层）。
    if (js.length > 8000) {
      throw StateError('js 过长（>8000）');
    }
    final budget = cdpTimeout ?? const Duration(seconds: 20);
    // C4：contextId 可能跨进程复用——调用方提供 uniqueContextId 时优先
    // 传递（executionContextCreated 缓存），失效由 Chrome 报错、上层映射
    // 为可读"上下文已过期"。
    // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate 。
    // R4-10：回包有界——serializationOptions.maxDepth 限深（experimental，
    // 老内核不支持直接报 CDP 方法参数错时去该参数重试一次，退化为默认序列化；
    // 上层 _clip 仍做最终截断）。
    // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#type-SerializationOptions 。
    // 校验：大 DOM 页 evaluate 取全量 outerHTML，回包长度有界（≤2MB）。
    Map<String, dynamic> params = {
      'expression': js,
      'awaitPromise': awaitPromise,
      'returnByValue': true,
      // R1-H3：原生 timeout 透传（experimental TimeDelta ms，老内核忽略）。
      'timeout': budget.inMilliseconds,
      'serializationOptions': {'serialization': 'deep', 'maxDepth': 10},
      // R3-M9：userGesture 透传（剪贴板等需手势 API 用）。
      if (userGesture) 'userGesture': true,
      // GB8：只读模式透传（read_only=true 时副作用表达式被 V8 拒绝）。
      if (throwOnSideEffect) 'throwOnSideEffect': true,
    };
    if (contextId != null) params['contextId'] = contextId;
    if (uniqueContextId != null && uniqueContextId.isNotEmpty) {
      params['uniqueContextId'] = uniqueContextId;
    }
    Map<String, dynamic> r;
    try {
      r = await send('Runtime.evaluate', params, budget);
    } on TimeoutException {
      // R1-H3：客户端超时后补发 terminateExecution 终止页面内执行。
      await terminateExecution();
      rethrow;
    } catch (e) {
      // 老内核 serializationOptions 不兼容即去参重试一次（仅参数错重试，
      // 有副作用 eval 不会 double-run：首发已被 Chrome 拒收未执行）。
      final msg = '$e';
      if (msg.contains('serializationOptions') ||
          msg.contains('serialization') ||
          msg.contains('Invalid parameters')) {
        params = Map<String, dynamic>.from(params)
          ..remove('serializationOptions');
        try {
          r = await send('Runtime.evaluate', params, budget);
        } on TimeoutException {
          await terminateExecution();
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    // 异常透出：此前调用方只读 result.result，JS 抛错时走 exceptionDetails，
    // jsonEncode 后模型看到的是空对象，误以为成功（Puppeteer 口径：异常即错）。
    // 兼容两种 CDP 形状：顶层 exceptionDetails（Runtime.evaluate 直出），
    // 或嵌套在 result 内。只按业务错误抛，不触发调用方重连重试
    // （重试会把有副作用的 eval 跑两次）。
    final payload = r['result'] as Map<String, dynamic>? ?? const {};
    Object? exc = r['exceptionDetails'] ?? payload['exceptionDetails'];
    exc ??= payload['exception'];
    final subtype = '${payload['subtype'] ?? ''}';
    if (exc is Map && exc.isNotEmpty || subtype == 'error') {
      final inner = exc is Map ? exc['exception'] : null;
      // GB8：description 优先——throwOnSideEffect 拒绝时 exceptionDetails.text
      // 仅 'Uncaught'，真正的拒绝原因（EvalError: Possible side-effect in
      // debug-evaluate）在 exception.description；普通 JS 异常的 description
      // 同样带错误类型前缀，比 text 更可读。无 description 回退 text。
      final desc = inner is Map ? inner['description'] : null;
      final detail = (desc is String && desc.isNotEmpty)
          ? desc
          : (exc is Map ? '${exc['text'] ?? exc}' : 'JS 执行异常');
      throw StateError('页面 JS 异常：$detail');
    }
    return r;
  }
}
