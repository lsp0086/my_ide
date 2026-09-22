import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_runner.dart' show AgentQuestion, ApprovalAction, PendingApproval;

/// 审批门禁：把 Completer / pending 状态从 AgentRunner 里抽出来，
/// UI 只订阅这个窄接口，不再直接依赖 Runner 的内部状态。
/// 审批按 FIFO 队列串行展示，连续 ask 不再覆盖挂死；endRun/requestCancel 兜底 complete。
class ApprovalGate extends ChangeNotifier {
  PendingApproval? _pendingApproval;
  AgentQuestion? _pendingQuestion;
  Completer<bool>? _approvalCompleter;
  Completer<String?>? _questionCompleter;
  // 待展示的审批队列：同一时刻 UI 只弹队首，前一个 resolve 后自动弹下一个。
  final List<_QueuedApproval> _approvalQueue = [];
  // 提问同样排队：并发 askUser 不再覆盖 _questionCompleter 导致悬挂，
  // 与审批队列同理串行展示。
  final List<_QueuedQuestion> _questionQueue = [];
  static const maxQueueLength = 64;
  static const _legacyWorkspace = '__legacy__';
  static const _allowlistTtl = Duration(days: 30);
  bool _cancelRequested = false;
  String _workspaceScope = _legacyWorkspace;

  PendingApproval? get pendingApproval => _pendingApproval;
  AgentQuestion? get pendingQuestion => _pendingQuestion;
  bool get cancelRequested => _cancelRequested;

  /// R2：本轮已信任的命令 key（安全命令"本轮都允许"后不再弹窗）。
  final Set<String> _trustedRunKeys = {};

  /// 持久白名单：用户"永久信任"后跨轮、跨重启生效，存 approval_allowlist。
  final Set<String> _persistentAllowlist = {};
  static const allowlistKey = 'approval_allowlist';
  bool _allowlistLoaded = false;

  void setWorkspace(String? workspaceRoot) {
    final scope = workspaceRoot?.trim();
    if (scope == null || scope.isEmpty || scope == _workspaceScope) return;
    _workspaceScope = scope;
    _persistentAllowlist.clear();
    _allowlistLoaded = false;
  }

  Future<void> _ensureAllowlist() async {
    if (_allowlistLoaded) return;
    _allowlistLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = <Map<String, dynamic>>[];
      String? rawJson;
      try {
        rawJson = prefs.getString(allowlistKey);
      } catch (_) {}
      if (rawJson != null) {
        final decoded = jsonDecode(rawJson);
        if (decoded is List) {
          entries.addAll(
            decoded.whereType<Map>().map(Map<String, dynamic>.from),
          );
        }
      } else {
        // 兼容旧 StringList：仅归入当前工作区，不再作为全局白名单使用。
        List<String> legacy = const [];
        try {
          legacy = prefs.getStringList(allowlistKey) ?? const [];
        } catch (_) {}
        for (final key in legacy) {
          entries.add({
            'key': key,
            'workspace': _workspaceScope,
            'expiresAt': now.add(_allowlistTtl).toIso8601String(),
          });
        }
      }
      var changed = rawJson == null && entries.isNotEmpty;
      for (final entry in entries) {
        final key = '${entry['key'] ?? ''}';
        final workspace = '${entry['workspace'] ?? _legacyWorkspace}';
        final expires = DateTime.tryParse('${entry['expiresAt'] ?? ''}');
        if (key.isEmpty ||
            workspace != _workspaceScope ||
            expires == null ||
            !expires.isAfter(now)) {
          changed = true;
          continue;
        }
        _persistentAllowlist.add(key);
      }
      if (changed) await _persistAllowlist();
    } catch (_) {}
  }

  Future<void> _persistAllowlist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final entries = <Map<String, dynamic>>[];
      String? rawJson;
      try {
        rawJson = prefs.getString(allowlistKey);
      } catch (_) {}
      if (rawJson != null) {
        final decoded = jsonDecode(rawJson);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            final entry = Map<String, dynamic>.from(item);
            final workspace = '${entry['workspace'] ?? _legacyWorkspace}';
            final expires = DateTime.tryParse('${entry['expiresAt'] ?? ''}');
            if (workspace != _workspaceScope &&
                expires != null &&
                expires.isAfter(now) &&
                '${entry['key'] ?? ''}'.isNotEmpty) {
              entries.add(entry);
            }
          }
        }
      }
      entries.addAll(
        _persistentAllowlist.map(
          (key) => {
            'key': key,
            'workspace': _workspaceScope,
            'expiresAt': now.add(_allowlistTtl).toIso8601String(),
          },
        ),
      );
      await prefs.setString(allowlistKey, jsonEncode(entries));
    } catch (_) {}
  }

  bool isTrusted(String? key) {
    if (key == null) return false;
    if (_trustedRunKeys.contains(key)) return true;
    if (_persistentAllowlist.contains(key)) return true;
    // 同步兜底：持久集尚未异步加载时直接读内存已加载部分；
    // 异步加载完成后以 _ensureAllowlist 为准，调用方可在需要时 await。
    return false;
  }

  Future<bool> isTrustedAsync(String? key) async {
    if (key == null) return false;
    if (_trustedRunKeys.contains(key)) return true;
    await _ensureAllowlist();
    return _persistentAllowlist.contains(key);
  }

  /// 永久信任并通过：写入持久白名单，跨轮生效。
  Future<void> trustPermanentlyAndApprove() async {
    final key = _pendingApproval?.trustKey;
    if (key != null) {
      _trustedRunKeys.add(key);
      await _ensureAllowlist();
      _persistentAllowlist.add(key);
      await _persistAllowlist();
    }
    resolveApproval(true);
  }

  Future<void> revokeTrust(String key) async {
    await _ensureAllowlist();
    _trustedRunKeys.remove(key);
    _persistentAllowlist.remove(key);
    await _persistAllowlist();
    notifyListeners();
  }

  /// 信任当前审批的 trustKey 并通过。无 trustKey 时等同普通通过。
  void trustCurrentAndApprove() {
    final key = _pendingApproval?.trustKey;
    if (key != null) _trustedRunKeys.add(key);
    resolveApproval(true);
  }

  void beginRun({String? workspaceRoot}) {
    // 先兜底旧 future：异常重入/定时任务重叠时旧 await 不悬挂，
    // 此前直接清空队列，旧 future 永久悬挂。
    for (final q in _approvalQueue) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    for (final q in _questionQueue) {
      if (!q.completer.isCompleted) q.completer.complete(null);
    }
    if (_approvalCompleter != null && !_approvalCompleter!.isCompleted) {
      _approvalCompleter!.complete(false);
    }
    if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
      _questionCompleter!.complete(null);
    }
    setWorkspace(workspaceRoot);
    _cancelRequested = false;
    _pendingApproval = null;
    _pendingQuestion = null;
    _approvalCompleter = null;
    _questionCompleter = null;
    _approvalQueue.clear();
    _questionQueue.clear();
    // 本轮信任只在本轮有效：上一轮"本轮都允许"不得泄漏到下一轮，
    // 否则 flutter test 信任后，下一轮 flutter test --evil 同前缀自动放行。
    _trustedRunKeys.clear();
    notifyListeners();
  }

  void endRun() {
    // 兜底 complete，避免异常结束时 await 悬挂。
    for (final q in _approvalQueue) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    _approvalQueue.clear();
    for (final q in _questionQueue) {
      if (!q.completer.isCompleted) q.completer.complete(null);
    }
    _questionQueue.clear();
    if (_approvalCompleter != null && !_approvalCompleter!.isCompleted) {
      _approvalCompleter!.complete(false);
    }
    if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
      _questionCompleter!.complete(null);
    }
    _pendingApproval = null;
    _pendingQuestion = null;
    _approvalCompleter = null;
    _questionCompleter = null;
    notifyListeners();
  }

  void requestCancel() {
    _cancelRequested = true;
    for (final q in _approvalQueue) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    _approvalQueue.clear();
    for (final q in _questionQueue) {
      if (!q.completer.isCompleted) q.completer.complete(null);
    }
    _questionQueue.clear();
    if (_approvalCompleter != null && !_approvalCompleter!.isCompleted) {
      _approvalCompleter!.complete(false);
    }
    if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
      _questionCompleter!.complete(null);
    }
    notifyListeners();
  }

  void _pumpApprovalQueue() {
    if (_approvalCompleter != null) return;
    if (_approvalQueue.isEmpty) {
      _pendingApproval = null;
      notifyListeners();
      return;
    }
    final next = _approvalQueue.removeAt(0);
    _pendingApproval = next.approval;
    _approvalCompleter = next.completer;
    notifyListeners();
  }

  void resolveApproval(bool approved) {
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    _pendingApproval = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    _pumpApprovalQueue();
  }

  void resolveQuestion(String? answer) {
    final completer = _questionCompleter;
    _questionCompleter = null;
    _pendingQuestion = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(answer);
    }
    _pumpQuestionQueue();
  }

  void _pumpQuestionQueue() {
    if (_questionCompleter != null) return;
    if (_questionQueue.isEmpty) {
      _pendingQuestion = null;
      notifyListeners();
      return;
    }
    final next = _questionQueue.removeAt(0);
    _pendingQuestion = next.question;
    _questionCompleter = next.completer;
    notifyListeners();
  }

  Future<bool> askApproval(PendingApproval approval) {
    if (_cancelRequested ||
        _approvalQueue.length + (_approvalCompleter == null ? 0 : 1) >=
            maxQueueLength) {
      return Future.value(false);
    }
    final completer = Completer<bool>();
    final entry = _QueuedApproval(approval, completer);
    _approvalQueue.add(entry);
    _pumpApprovalQueue();
    // 1.6 审批超时：5 分钟无人点按拒绝处理，避免无限挂死。
    // 关窗/取消仍走 endRun/requestCancel 兜底。
    // 超时只处理属于自己的排队项：排队中移除本项，已展示则按正常 resolve，
    // 避免后排超时误拒队首导致队列错位。
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        if (completer.isCompleted) return false;
        completer.complete(false);
        if (_approvalCompleter == completer) {
          resolveApproval(false);
        } else {
          _approvalQueue.remove(entry);
        }
        return false;
      },
    );
  }

  Future<String?> askUser(AgentQuestion question) {
    if (_cancelRequested ||
        _questionQueue.length + (_questionCompleter == null ? 0 : 1) >=
            maxQueueLength) {
      return Future.value(null);
    }
    final completer = Completer<String?>();
    final entry = _QueuedQuestion(question, completer);
    _questionQueue.add(entry);
    _pumpQuestionQueue();
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        if (completer.isCompleted) return null;
        completer.complete(null);
        if (_questionCompleter == completer) {
          resolveQuestion(null);
        } else {
          _questionQueue.remove(entry);
        }
        return null;
      },
    );
  }

  Future<bool> shouldProceed(ApprovalAction action, PendingApproval approval) {
    // 取消优先：用户点取消后 auto 也不再执行，避免取消后仍写文件。
    if (_cancelRequested) return Future.value(false);
    switch (action) {
      case ApprovalAction.auto:
        return Future.value(true);
      case ApprovalAction.deny:
        return Future.value(false);
      case ApprovalAction.ask:
        return askApproval(approval);
    }
  }
}

class _QueuedApproval {
  _QueuedApproval(this.approval, this.completer);

  final PendingApproval approval;
  final Completer<bool> completer;
}

class _QueuedQuestion {
  _QueuedQuestion(this.question, this.completer);

  final AgentQuestion question;
  final Completer<String?> completer;
}
