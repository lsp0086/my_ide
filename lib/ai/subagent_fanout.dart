import 'dart:async';

import 'agent_tools.dart';

/// 并行扇出任务。
class FanoutTask {
  FanoutTask({
    required this.id,
    required this.task,
    this.files = const [],
    // R8-S1：mode/todos 透传——此前并行链路只带 task/files，
    // 主循环经 runParallel 的 spawn 恒丢 mode，plan 恒走 research。
    this.mode = 'research',
    this.todos = const [],
  });

  final String id;
  final String task;
  final List<String> files;
  final String mode;
  final List<String> todos;
}

/// 单个扇出结果。
/// R5并行写竞争串行化：OpenHands共享workspace并行写已知坑
/// https://engineering.viblo.asia/p/openhands-deep-dive-build-your-own-guide-OXLA0jKMJGr
/// （采纳：touch交集即串行化；不采纳：共享写）+ LangGraph同key单步单值
/// https://forum.langchain.com/t/how-to-partially-stop-the-langgraph-workflow/4239
/// （采纳：同文件并发写必须reducer合并；不采纳：last-write-wins）。
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
    // R16R4：整批超时结构化标记——此前调用方凭output.contains('整批超时')
    // 文本定性，文案一改即失配。现占位带timedOut=true，文本仅展示用。
    this.timedOut = false,
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

  /// R16R4：整批超时结构化标记。
  final bool timedOut;
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

  /// R5写交集检测：并行分支touchedFiles交集非空即同文件并发写，
  /// 调用方须串行化或打回（OpenHands共享写坑/LangGraph单步单值口径）。
  static Set<String> conflictingFiles(List<FanoutResult> rs) {
    final seen = <String>{};
    final conflicts = <String>{};
    for (final r in rs) {
      for (final f in r.touchedFiles) {
        final key = f.trim();
        if (key.isEmpty) continue;
        if (!seen.add(key)) conflicts.add(key);
      }
    }
    return conflicts;
  }
}

/// 并行扇出：[tasks] 用 [runner] 并发执行（上限 [maxConcurrency]，默认3），
/// 结果评审选优（最长有效输出优先，标注来源）。
///
/// [runner] 单调兼容既有单子代理回调：输入单个任务，返回工具结果。
/// [shouldCancel] 取消检查：为 true 时不再等待在途子 Agent，直接返回已完成结果，
/// 避免取消后仍等最慢分支（60-600s）。
/// [overallTimeout] R4-A1 整批总超时：多批串行时单任务超时逐批收敛仍可
/// 拖长（N 批×60s），超限剩余项回中断占位不继续发新批，在途孤儿各自
/// 超时+调用方取消广播自收。默认按 批数×任务超时 兜底。
Future<FanoutReview> runParallel(
  List<FanoutTask> tasks,
  Future<AgentToolResult> Function(FanoutTask task) runner, {
  int maxConcurrency = 3,
  bool Function()? shouldCancel,
  // 发起时的世代号：透传给每个结果，调用方在 _runSubagent finally
  // 里凭 gen 丢弃旧轮晚到，避免中断占位后孤儿又进嵌套区/账本。
  int gen = 0,
  // R4-O1：边到边流式回调——长扇出每完成一个即回调，不改wait-all默认。
  void Function(FanoutResult result)? onResult,
  // 超时或整批放弃时通知调用方取消对应任务。timeout 本身不取消 Future。
  void Function(FanoutTask task)? onAbandon,
  // R6-O1：单任务超时——慢分支超时即失败占位，不堵整批。
  // R3-A7：默认60s超时——此前默认无超时，永挂runner+无取消即卡死。
  Duration? taskTimeout,
  Duration? overallTimeout,
}) async {
  final effectiveTimeout = taskTimeout ?? const Duration(seconds: 60);
  var limit = maxConcurrency;
  if (limit < 1) limit = 1;
  if (limit > 3) limit = 3;
  // R4-A1：整批总超时默认兜底——批数×单任务超时+余量，不再靠调用方传参。
  final batchCount = (tasks.length + limit - 1) ~/ limit;
  final effectiveOverall = overallTimeout ??
      Duration(
        microseconds:
            effectiveTimeout.inMicroseconds * (batchCount > 0 ? batchCount : 1) +
                const Duration(seconds: 10).inMicroseconds,
      );
  final overallDeadline =
      effectiveOverall.inMicroseconds > 0 ? DateTime.now().add(effectiveOverall) : null;
  final results = <FanoutResult>[];
  // batch 内去重：重复 id 只跑首个，后续直接返回占位，避免双 pending 取同一结果。
  // 第8轮收敛：空/空白 id 不参与去重——此前空 id 两任务即判重复，
  // 第二个被占位跳过致调研丢失。对齐 Roo Code new_task 隔离口径：
  // https://roocodeinc.github.io/Roo-Code/update-notes/v3.44/
  final seenIds = <String>{};
  bool dedupable(String id) => id.trim().isNotEmpty;
  for (var i = 0; i < tasks.length; i += limit) {
    // R4-A1：整批超时即停发新批——此前多批串行无上限，9 子 Agent
    // 逐批 60s 最坏拖 3min+ 才续轮。超限剩余批直接回超时占位（R6 定性：
    // 此前与取消分支共用“用户中断”措辞，非取消超时被下游误记为用户取消），
    // 在途批由单任务超时+取消广播自收，不静默丢弃。
    if (overallDeadline != null && DateTime.now().isAfter(overallDeadline)) {
      for (var j = i; j < tasks.length; j++) {
        final t = tasks[j];
        if (dedupable(t.id) && !seenIds.add(t.id)) {
          results.add(
            FanoutResult(
              source: t.id,
              ok: true,
              output: '重复任务 id，已跳过：${t.id}',
              gen: gen,
            ),
          );
          continue;
        }
        results.add(
          FanoutResult(
            source: t.id,
            ok: false,
            output: '子Agent整批超时，已熔断。',
            gen: gen,
            timedOut: true,
          ),
        );
      }
      break;
    }
    var end = i + limit;
    if (end > tasks.length) end = tasks.length;
    final batch = tasks.sublist(i, end);
    final effective = <FanoutTask>[];
    for (final t in batch) {
      if (dedupable(t.id) && !seenIds.add(t.id)) {
        // 重复 id 是调用方去重问题，不应计入连续失败熔断：此前 ok:false
        // 会被下游 recordToolFailure 误熔断。改为 ok:true 空占位跳过。
        // 世代透传：此前占位 gen 默认为 0，调用方按 gen!=_subagentGen
        // 当旧轮孤儿丢弃，反把当前批重复项误判为旧世代。
        results.add(
          FanoutResult(
            source: t.id,
            ok: true,
            output: '重复任务 id，已跳过：${t.id}',
            gen: gen,
          ),
        );
        continue;
      }
      effective.add(t);
    }
    if (effective.isEmpty) continue;
    final futures = effective.map((t) async {
      try {
        // R6-O1同口径：有超时即限时等，超时按失败占位有序回填。
        // R8-超时下界：0/负数Duration此前即全部分支必超时（timeout(0)恒抛），
        // 调用方误传即整批失败。现非正超时视为未设置。
        // R3-A7：默认60s（effectiveTimeout恒正），永挂分支超时回填不卡死。
        // 第11轮R1-1：超时文案按实际渲染——此前硬编码60s，自定义超时误导排查。
        final bounded = effectiveTimeout.inMicroseconds > 0
            ? effectiveTimeout
            : null;
        final timeoutLabel = bounded == null
            ? '不限时'
            : bounded.inMilliseconds < 1000
                ? '${bounded.inMilliseconds}ms'
                : '${(bounded.inMilliseconds / 1000).toStringAsFixed(bounded.inMilliseconds % 1000 == 0 ? 0 : 1)}s';
        final r = bounded == null
            ? await runner(t)
            : await runner(t).timeout(
                bounded,
                onTimeout: () {
                  try {
                    onAbandon?.call(t);
                  } catch (_) {}
                  return AgentToolResult(
                    ok: false,
                    output: '子Agent执行超时（$timeoutLabel）已熔断。',
                  );
                },
              );
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
      // R1-D7：每future单次then登记完成即回调——此前wait全收齐才按
      // 输入序回调，长尾堵住早完成分支。现完成即回调（去重防双调）。
      // R4-A1：无取消检查分支同样受整批超时约束——超时即回失败占位
      // 不干到最长分支，在途孤儿由单任务超时自收。
      // R11-6-A 有序回调：到达序emitNow与收齐后输入序补调混用，下游嵌套区/
      // 账本在取消/非取消分支下顺序不一致。现onResult只走到达序一次，
      // 收齐后不再按输入序补调（results数组仍按输入序对齐供选优）。
      final calledBack = <int>{};
      void emitNow(int i, FanoutResult r) {
        if (onResult == null || !calledBack.add(i)) return;
        try {
          onResult(r);
        } catch (_) {}
      }

      for (var i = 0; i < effective.length; i++) {
        futures[i].then((r) => emitNow(i, r), onError: (_) {});
      }
      final remain = overallDeadline?.difference(DateTime.now());
      final List<FanoutResult> outputs;
      if (remain != null && remain <= Duration.zero) {
        for (final t in effective) {
          try {
            onAbandon?.call(t);
          } catch (_) {}
        }
        outputs = [
          for (final t in effective)
            FanoutResult(
              source: t.id,
              ok: false,
              output: '子Agent整批超时，已熔断。',
              gen: gen,
              timedOut: true,
            ),
        ];
      } else if (remain != null) {
        outputs = await Future.wait(
          futures,
          eagerError: false,
        ).timeout(
          remain,
          onTimeout: () {
            for (final t in effective) {
              try {
                onAbandon?.call(t);
              } catch (_) {}
            }
            return [
              for (final t in effective)
                FanoutResult(
                  source: t.id,
                  ok: false,
                  output: '子Agent整批超时，已熔断。',
                  gen: gen,
                  timedOut: true,
                ),
            ];
          },
        );
      } else {
        outputs = await Future.wait(futures, eagerError: false);
      }
      // R11-6-A同口径：到达序已逐个emit，此处不再按输入序补调，
      // 否则同一结果双回调致下游嵌套区顺序抖动。去重集合保证晚到不重调。
      for (var i = 0; i < outputs.length; i++) {
        calledBack.add(i);
      }
      results.addAll(outputs);
      continue;
    }
    // 取消感知等待：逐项收集保留部分完成，全有或全无会丢已产出调研。
    // 在途 future 无法强制取消（Dart 语义），只不再等待；
    // 真正的 requestCancel 由调用方广播（Runner.requestCancel 遍历在途 runtime）。
    // 监听膨胀修复：此前每 50ms 轮询都新建一次 Future.any + N 个 .then，
    // 3 并发×60s 超时即 3600 个临时监听堆在同一 future 上直到完成。
    // 改为每 future 单次 then 登记完成表，轮询只 delay 不建监听。
    // R1-并行覆盖竞争收敛：completed 按下标键（对齐 shouldCancel==null 分支
    // outputs 按 futures 输入序）：同批空 id 不再互盖，收集按 effective 序；
    // 来源 Roo Code new_task 隔离 safeguards
    // https://roocodeinc.github.io/Roo-Code/update-notes/v3.44.2/ 与
    // Cline Plan/Act 双模串行语义 https://docs.cline.bot/core-workflows/plan-and-act
    // （采纳：同批有序收集+空 id 不丢；不采纳：worktree 物理隔离，见 README 已知待办）。
    final completed = <int, FanoutResult>{};
    for (var i = 0; i < effective.length; i++) {
      // 取消感知 then 异常兜底：runner 内部同步抛时此前无 onError，
      // 该 id 永不入表、无取消即 50ms 空转到最慢分支。
      futures[i].then((r) {
        completed[i] = r;
      }, onError: (Object e) {
        completed[i] = FanoutResult(
          source: effective[i].id,
          ok: false,
          output: '失败：$e',
          gen: gen,
        );
      });
    }
    while (completed.length < effective.length) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (completed.length >= effective.length) break;
      // R4-A1：取消感知分支同样受整批超时约束，超限即停等回失败占位。
      if (overallDeadline != null &&
          !DateTime.now().isBefore(overallDeadline)) {
        for (var i = 0; i < effective.length; i++) {
          if (completed.containsKey(i)) continue;
          try {
            onAbandon?.call(effective[i]);
          } catch (_) {}
        }
        break;
      }
      if (shouldCancel()) {
        for (var i = 0; i < effective.length; i++) {
          if (completed.containsKey(i)) continue;
          try {
            onAbandon?.call(effective[i]);
          } catch (_) {}
        }
        break;
      }
    }
    final collected = <FanoutResult>[];
    final seenSources = <String>{for (final r in results) r.source};
    var emptyQueued = 0;
    var emptySeen = 0;
    for (var i = 0; i < effective.length; i++) {
      final t = effective[i];
      final r = completed[i];
      // 首个 wins：同 id 晚到重复结果直接丢弃，避免后赢者覆盖已收集的首个结果
      // （与调用方 byId.putIfAbsent 同口径；开源幂等回调：按 tool_call.id 对齐）。
      // 空 id 恒收集：空/空白 id 不参与去重（与首轮 seenIds 同口径），
      // 按本批空位计数逐个收集，不走来源集合判重，保证 results 与 tasks 对齐。
      if (!dedupable(t.id)) emptySeen++;
      if (r == null) continue;
      if (!dedupable(t.id)) {
        if (emptyQueued < emptySeen) {
          emptyQueued++;
          collected.add(r);
        }
        continue;
      }
      if (seenSources.add(t.id)) {
        collected.add(r);
      }
    }
    results.addAll(collected);
    // R4-O1同口径：取消感知分支同样边到边回调已收集项。
    if (onResult != null) {
      for (final r in collected) {
        try {
          onResult(r);
        } catch (_) {}
      }
    }
    if (completed.length >= effective.length) continue;
    // 当前批取消截断回填后继续下一批同样回填：此前 break 丢尾批次，
    // 调用方非取消态把缺失当“用户拒绝”。尾批同样按中断占位补齐。
    // 空 id 同样按位回填，不走 results.any(source)（两空 id 会误判已收集）。
    final collectedSources = <String>{for (final r in collected) r.source};
    var collectedEmpties = collected.where((r) => !dedupable(r.source)).length;
    for (final t in effective) {
      if (!dedupable(t.id)) {
        if (collectedEmpties > 0) {
          collectedEmpties--;
          continue;
        }
      } else if (collectedSources.contains(t.id) ||
          results.any((r) => r.source == t.id)) {
        continue;
      }
      results.add(
        FanoutResult(source: t.id, ok: false, output: '用户中断，已取消。', gen: gen),
      );
    }
    // 取消后剩余批次不再发起执行，直接按中断占位补齐，保证 results 与 tasks 对齐。
    // 第8轮收敛：空 id 同样不去重，与首轮去重同口径。
    for (var j = i + limit; j < tasks.length; j++) {
      final t = tasks[j];
      if (!dedupable(t.id) || seenIds.add(t.id)) {
        results.add(
          FanoutResult(
            source: t.id,
            ok: false,
            output: '用户中断，已取消。',
            gen: gen,
          ),
        );
      } else {
        results.add(
          FanoutResult(
            source: t.id,
            ok: true,
            output: '重复任务 id，已跳过：${t.id}',
            gen: gen,
          ),
        );
      }
    }
    break;
  }
  final valid = results.where((r) => r.ok && r.output.trim().isNotEmpty);
  // R2-F1：占位不污染选优——此前重复id占位ok:true可被选为best拼入上下文。
  // 现 best 过滤占位文本，全占位批 best.ok==false 不熔断不拼上下文。
  // R8-F1：中断占位同样过滤——取消截断回填ok:false“用户中断，已取消”，
  // 全失败分支按最长输出会选中中断文本拼上下文。现与重复占位同口径过滤。
  bool isPlaceholder(FanoutResult r) =>
      r.output.startsWith('重复任务 id，已跳过') ||
      r.timedOut ||
      r.output.contains('子Agent整批超时，已熔断');
  // R4-A1：整批超时占位同样不污染熔断/上下文——与重复占位/中断占位同口径，
  // best 过滤后失败分支才参与，全占位批 best.ok==false 不熔断不拼占位文本。
  bool isInterrupted(FanoutResult r) =>
      r.output.contains('用户中断，已取消');
  final validNonPlaceholder =
      valid.where((r) => !isPlaceholder(r) && !isInterrupted(r));
  FanoutResult best;
  if (validNonPlaceholder.isEmpty) {
    final nonPlaceholder = results.where(
        (r) => !isPlaceholder(r) && !isInterrupted(r));
    if (nonPlaceholder.isEmpty) {
      // 全占位/全中断：best.ok==false，不拼占位文本进上下文。
      final fails = results.where((r) =>
          !isPlaceholder(r) && !isInterrupted(r) && !r.ok);
      if (fails.isNotEmpty) {
        best = fails.reduce(
          (a, b) => a.output.length >= b.output.length ? a : b,
        );
      } else {
        best = results.isEmpty
            ? FanoutResult(source: 'none', ok: false, output: '（无任务）', gen: gen)
            : FanoutResult(
                source: results.first.source,
                ok: false,
                output: '（重复任务已跳过，无有效结果）',
                gen: results.first.gen,
              );
      }
    } else {
      best = nonPlaceholder.reduce(
        (a, b) => a.output.length >= b.output.length ? a : b,
      );
    }
  } else {
    best = validNonPlaceholder.reduce(
      (a, b) => a.output.length >= b.output.length ? a : b,
    );
  }
  return FanoutReview(results: results, best: best);
}
