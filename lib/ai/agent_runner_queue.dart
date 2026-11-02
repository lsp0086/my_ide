part of 'agent_runner.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// 拆分说明：AgentRunner 原为单一 ChangeNotifier 子类，类内调用 notifyListeners()
// 合法；按功能拆为同库 part（扩展成员与类成员同库），调用点行为不变，
// 此处忽略"扩展内不得调用 protected 成员"的静态告警。


/// 追问队列与跟进轮
extension AgentRunnerQueue on AgentRunner {
  /// R-QUEUE-OBS：生产轮末 drain 直读桶，此 getter 供测试/观测用。
  @visibleForTesting
  bool get hasQueued =>
      pendingQueue.isNotEmpty ||
      _pendingQueuesBySession.values.any((q) => q.isNotEmpty);
  /// 指定会话的排队追问快照（只读）；空 sessionId 即默认桶。
  /// R-QUEUE-OBS：测试/观测用。
  @visibleForTesting
  List<String> pendingQueueOf(String sessionId) => sessionId.isEmpty
      ? List.unmodifiable(pendingQueue)
      : List.unmodifiable(
          _pendingQueuesBySession[sessionId] ?? const <String>[],
        );
  /// 队列有界50：满后丢最旧保最新追问可用。
  void _trimQueue(List<String> pendingQueue) {
    while (pendingQueue.length > 50) {
      pendingQueue.removeAt(0);
    }
  }
  /// 运行中追问入队：返回该会话队列长度。空文本直接忽略返回当前长度。
  /// R15R4：队列有界50——此前无限入队，幻觉循环高频 queue 即内存膨胀。
  int queueMessage(String text, {String sessionId = ''}) {
    final t = text.trim();
    // 空 sessionId 入默认桶 pendingQueue；其余按会话分桶，取消互不牵连。
    final queue = sessionId.isEmpty
        ? pendingQueue
        : _pendingQueuesBySession.putIfAbsent(sessionId, () => <String>[]);
    if (t.isEmpty) return queue.length;
    queue.add(text);
    _trimQueue(queue);
    notifyListeners();
    return queue.length;
  }
  /// 轮末消费本会话排队追问：取出最多 [AgentRunner._queuedFollowUpsPerTurn] 条按序
  /// 拼接为一条新用户消息，由调用方继续下一轮；队列为空返回 null。
  /// R3-A1：空会话同样消费全局桶——此前只读分桶，全局桶只写不消费，
  /// hasQueued两桶都算致UI显示有排队但永远不跑。
  String? _drainQueuedFollowUps(String sessionId) {
    final queue = sessionId.isEmpty
        ? pendingQueue
        : _pendingQueuesBySession[sessionId];
    if (queue == null || queue.isEmpty) return null;
    final take = queue.length > AgentRunner._queuedFollowUpsPerTurn
        ? AgentRunner._queuedFollowUpsPerTurn
        : queue.length;
    var merged = queue.sublist(0, take).join('\n\n');
    queue.removeRange(0, take);
    // R3-A2：图片标记与实际桶对齐——入队时文本写的是当次张数，
    // 但两桶截尾保最新20，旧图被丢后文本仍宣称 N 张。轮末按本会话
    // 实际留存张数重写标记，文本与续传数量一致不再对不上。
    final pendingImgs = _pendingImagesBySession[sessionId];
    if (pendingImgs != null && pendingImgs.isNotEmpty) {
      final actual = pendingImgs.length;
      merged = merged.replaceAllMapped(
        RegExp(r'（排队追问附 \d+ 张图片，已随本轮图片续传）'),
        (m) => '（排队追问附 $actual 张图片，已随本轮图片续传）',
      );
    }
    // R3-A1续：全局桶是final列表只清空不删键，分桶空即删键。
    if (queue.isEmpty && sessionId.isNotEmpty) {
      _pendingQueuesBySession.remove(sessionId);
    }
    notifyListeners();
    return merged;
  }

  /// G3-R2 运行中转向：工具边界前取走本会话排队文本，合并为一条 steer
  /// 注入（条数上限与轮末 drain 同款 _queuedFollowUpsPerTurn）。不消耗
  /// 图片桶：图片仍随轮末 drain 同轮续传（R1-A5 口径不变），仅按实际
  /// 留存张数重写排队标记防文不对图。队列为空返回 null。
  /// 取消态不在此判定：调用点（工具步循环）已先查取消，且 requestCancel
  /// 本就按会话清队列，双保险不重复注入。
  /// G3-R2：工具边界前取本会话排队转向输入（合并上限与轮末 drain 同款）。
  /// 规则1自检修复：取尽本会话队列文本时同步消费图片桶——图片归属已消费
  /// 的排队消息，不消费则本轮 drain 返 null 即搁浅、滞留图片错绑后续无关
  /// 消息；队列仍有残留时不消费（图片留给其归属消息，原口径续传）。
  /// [includeImages] 仅视觉模型为 true：非视觉模型送图只会浪费/400，图片
  /// 留在桶内按轮末/后续 run 原口径处理。
  ({String text, List<String> images, List<String> imageRefs})?
  _takeSteerInjection(String sessionId, {bool includeImages = false}) {
    final queue = sessionId.isEmpty
        ? pendingQueue
        : _pendingQueuesBySession[sessionId];
    if (queue == null || queue.isEmpty) return null;
    final take = queue.length > AgentRunner._queuedFollowUpsPerTurn
        ? AgentRunner._queuedFollowUpsPerTurn
        : queue.length;
    var merged = queue.sublist(0, take).join('\n\n');
    queue.removeRange(0, take);
    final queueEmptied = queue.isEmpty;
    if (queueEmptied && sessionId.isNotEmpty) {
      _pendingQueuesBySession.remove(sessionId);
    }
    var images = const <String>[];
    var imageRefs = const <String>[];
    final willTakeImages =
        includeImages &&
        queueEmptied &&
        (_pendingImagesBySession[sessionId]?.isNotEmpty ?? false);
    if (willTakeImages) {
      images = List.unmodifiable(
        _pendingImagesBySession.remove(sessionId) ?? const [],
      );
      imageRefs = List.unmodifiable(
        _pendingImageRefsBySession.remove(sessionId) ?? const [],
      );
      merged = merged.replaceAllMapped(
        RegExp(r'（排队追问附 \d+ 张图片，[^）]+）'),
        (m) => '（排队追问附 ${images.length} 张图片，已随本轮转向图片续传）',
      );
    } else {
      // R3-A2 同口径：按本会话实际留存图片数重写标记（steer 注入时图片
      // 尚未进上下文，将在本轮结束后随下一条消息续传）。
      final pendingImgs = _pendingImagesBySession[sessionId];
      if (pendingImgs != null && pendingImgs.isNotEmpty) {
        final actual = pendingImgs.length;
        merged = merged.replaceAllMapped(
          RegExp(r'（排队追问附 \d+ 张图片，[^）]+）'),
          (m) => '（排队追问附 $actual 张图片，将在本轮结束后随下一条消息续传）',
        );
      }
    }
    notifyListeners();
    final text = merged.trim();
    if (text.isEmpty) return null;
    return (text: '【运行中转向】$text', images: images, imageRefs: imageRefs);
  }
}
