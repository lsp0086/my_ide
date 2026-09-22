import 'dart:async';

import 'agent_tools.dart';

/// 并行扇出任务。
class FanoutTask {
  FanoutTask({required this.id, required this.task, this.files = const []});

  final String id;
  final String task;
  final List<String> files;
}

/// 单个扇出结果。
class FanoutResult {
  FanoutResult({
    required this.source,
    required this.ok,
    required this.output,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.untrusted = true,
    this.sourceLabel = 'subagent',
    this.touchedFiles = const [],
    // 取消截断时在途分支稍后晚到：调用方凭此世代号丢弃，
    // 避免中断占位已写回后孤儿摘要又进嵌套区/账本造成分叉。
    this.gen = 0,
  });

  final String source;
  final bool ok;
  final String output;
  final int promptTokens;
  final int completionTokens;

  /// 子 Agent 输出默认不可信：透传给主循环后须参与 untrusted 提级，
  /// 否则主循环会把子代理的调研文字当可信指令执行。
  final bool untrusted;

  /// 来源标签：写回 tool 消息时标注，便于主循环引用与排查。
  final String sourceLabel;
  final List<String> touchedFiles;

  /// 发起时的世代号：取消截断后晚到的孤儿结果调用方凭此丢弃，
  /// 避免中断占位已写回后孤儿摘要又进嵌套区/账本造成分叉。
  final int gen;
}

/// 扇出评审：全部结果 + 选优 + 合并文本（标注来源）。
class FanoutReview {
  FanoutReview({required this.results, required this.best});

  final List<FanoutResult> results;
  final FanoutResult best;

  /// 合并输出：每段标注来源，便于主循环引用。
  String get combined => results
      .map((r) => '【来源 ${r.source}】\n${r.output}')
      .join('\n\n---\n\n');
}

/// 并行扇出：[tasks] 用 [runner] 并发执行（上限 [maxConcurrency]，默认3），
/// 结果评审选优（最长有效输出优先，标注来源）。
///
/// [runner] 单调兼容既有单子代理回调：输入单个任务，返回工具结果。
/// [shouldCancel] 取消检查：为 true 时不再等待在途子 Agent，直接返回已完成结果，
/// 避免取消后仍等最慢分支（60-600s）。
Future<FanoutReview> runParallel(
  List<FanoutTask> tasks,
  Future<AgentToolResult> Function(FanoutTask task) runner, {
  int maxConcurrency = 3,
  bool Function()? shouldCancel,
  // 发起时的世代号：透传给每个结果，调用方在 _runSubagent finally
  // 里凭 gen 丢弃旧轮晚到，避免中断占位后孤儿又进嵌套区/账本。
  int gen = 0,
}) async {
  var limit = maxConcurrency;
  if (limit < 1) limit = 1;
  if (limit > 3) limit = 3;
  final results = <FanoutResult>[];
  // batch 内去重：重复 id 只跑首个，后续直接返回占位，避免双 pending 取同一结果。
  final seenIds = <String>{};
  for (var i = 0; i < tasks.length; i += limit) {
    var end = i + limit;
    if (end > tasks.length) end = tasks.length;
    final batch = tasks.sublist(i, end);
    final effective = <FanoutTask>[];
    for (final t in batch) {
      if (!seenIds.add(t.id)) {
        results.add(
          FanoutResult(source: t.id, ok: false, output: '重复任务 id，已跳过：${t.id}'),
        );
        continue;
      }
      effective.add(t);
    }
    if (effective.isEmpty) continue;
    final futures = effective.map((t) async {
      try {
        final r = await runner(t);
        return FanoutResult(
          source: t.id,
          ok: r.ok,
          output: r.output,
          promptTokens: r.promptTokens ?? 0,
          completionTokens: r.completionTokens ?? 0,
          untrusted: r.untrusted,
          sourceLabel: r.source ?? 'subagent',
          touchedFiles: r.touchedFiles,
          gen: gen,
        );
      } catch (e) {
        return FanoutResult(source: t.id, ok: false, output: '失败：$e', gen: gen);
      }
    }).toList();
    if (shouldCancel == null) {
      final outputs = await Future.wait(futures, eagerError: false);
      results.addAll(outputs);
      continue;
    }
    // 取消感知等待：逐项收集保留部分完成，全有或全无会丢已产出调研。
    // 在途 future 无法强制取消（Dart 语义），只不再等待；
    // 真正的 requestCancel 由调用方广播（Runner.requestCancel 遍历在途 runtime）。
    final pending = Map<String, Future<FanoutResult>>.fromIterables(
      effective.map((t) => t.id),
      futures,
    );
    final collected = <FanoutResult>[];
    // 取消检查节流：每次 Future.any 50ms 超时复检一次。
    // 高频 shouldCancel 会读 _cancelRequested/_gate 状态，50ms 粒度已足够，
    // 此前 while 头无条件 shouldCancel() 在 pending 为空的空转轮询中同样高频触发。
    while (pending.isNotEmpty) {
      // 50ms 粒度轮询：等任一项完成或超时，超时即复检取消。
      String? settled;
      try {
        settled = await Future.any(
          pending.entries.map((e) => e.value.then((_) => e.key)),
        ).timeout(const Duration(milliseconds: 50));
      } on TimeoutException {
        settled = null;
      }
      if (settled != null) {
        final r = await pending.remove(settled);
        if (r != null) collected.add(r);
        continue;
      }
      if (shouldCancel()) break;
    }
    results.addAll(collected);
    if (pending.isEmpty) continue;
    for (final t in effective) {
      if (results.any((r) => r.source == t.id)) continue;
      results.add(
        FanoutResult(source: t.id, ok: false, output: '用户中断，已取消。', gen: gen),
      );
    }
    break;
  }
  final valid = results.where((r) => r.ok && r.output.trim().isNotEmpty);
  FanoutResult best;
  if (valid.isEmpty) {
    best = results.isEmpty
        ? FanoutResult(source: 'none', ok: false, output: '（无任务）')
        : results.reduce((a, b) => a.output.length >= b.output.length ? a : b);
  } else {
    best = valid.reduce(
      (a, b) => a.output.length >= b.output.length ? a : b,
    );
  }
  return FanoutReview(results: results, best: best);
}
