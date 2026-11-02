part of 'agent_tools.dart';

/// 同文件写串行队列
extension AgentToolsWriteChains on AgentTools {
  /// 实例便捷封装：按 rootPath+rel 算规范化绝对路径后串行。
  /// 锁键用 realpath 消别名：词法不同的 symlink/大小写别名指向同一文件时
  /// 必须同键，否则并行双写绕过串行直接互盖。
  Future<T> _serializeFileWrite<T>(List<String> rels, Future<T> Function() fn) {
    // R5-07：键单源——直出canonical键，不再此地双算realpath+归一，
    // 此前与serializeFileWrites内canonical双算口径分裂即互盖。
    // R1-F1：写盘统一关口等restore——直调execute()不再绕过互斥。
    // 超时按失败结果返回（不抛错）：调用方按Result口径处理，与
    // ToolRegistry层"版本恢复进行中"失败返回同口径。
    Future<T> gated() async {
      final busy = restoreBusyCheck;
      final gen = restoreGenCheck;
      if (busy != null && gen != null && busy()) {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        DateTime? quietSince;
        while (true) {
          if (!DateTime.now().isBefore(deadline)) {
            throw StateError('版本恢复进行中，写盘已推迟避免丢写：请稍后重试');
          }
          if (busy()) {
            quietSince = null;
          } else {
            quietSince ??= DateTime.now();
            if (DateTime.now().difference(quietSince) >=
                const Duration(milliseconds: 200)) {
              break;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      return fn();
    }

    final keys = rels
        .map((r) {
          try {
            final abs = p.normalize(p.isAbsolute(r) ? r : p.join(rootPath, r));
            return AgentTools.canonicalFileKeyForTest(abs);
          } catch (_) {
            return '';
          }
        })
        .where((e) => e.isNotEmpty)
        .toList();
    if (keys.isEmpty) return gated();
    return AgentTools.serializeFileWrites(keys, gated);
  }
  Future<T> _serializeTodoWrite<T>(Future<T> Function() fn) {
    // R11R4：与 AgentTools.serializeFileWrites 同口径自动清链——此前只增不删，
    // 进程常驻下 AgentTools._todoWriteChains 按 root 无界膨胀；完成后无后排即删 key。
    // R1-T5：链必须含fn体——此前prev.then((_) {})只排哨兵不排fn，
    // Future.wait双写并发同时进fn致load→merge→save互盖丢b。
    // 现tail为本次fn完成 future，后排await prev即等本次fn落盘。
    // 第2轮R2-2：超时fail-closed与文件链同口径——此前超时打日志后放行进fn，
    // 网络盘卡住时连续两次todo_write可与前排load→merge→save并发互盖丢todo。
    // 现30s只告警仍串行等队头，后排阻塞不互盖。
    final key = _todoRootKey();
    final prev = AgentTools._todoWriteChains[key] ?? Future<void>.value();
    final completer = Completer<T>();
    final tail = completer.future.then((_) {}).catchError((_) {});
    AgentTools._todoWriteChains[key] = tail;
    // R-CHAIN-TIMER：同上，改可取消 Timer。
    final warnTimer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        AppLogger.instance.error(
          'todochain',
          'todo链前排等待超时(30s)，仍串行等待避免互盖',
          null,
        );
      }
    });
    prev.then((_) async {
          try {
            completer.complete(await fn());
          } catch (e, st) {
            completer.completeError(e, st);
          } finally {
            warnTimer.cancel();
            final cur = AgentTools._todoWriteChains[key];
            if (identical(cur, tail)) AgentTools._todoWriteChains.remove(key);
          }
        });
    return completer.future;
  }
}
