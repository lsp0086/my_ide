import 'dart:async';

import 'package:flutter/material.dart';

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
  bool _cancelRequested = false;

  PendingApproval? get pendingApproval => _pendingApproval;
  AgentQuestion? get pendingQuestion => _pendingQuestion;
  bool get cancelRequested => _cancelRequested;

  void beginRun() {
    _cancelRequested = false;
    _pendingApproval = null;
    _pendingQuestion = null;
    _approvalCompleter = null;
    _questionCompleter = null;
    _approvalQueue.clear();
    notifyListeners();
  }

  void endRun() {
    // 兜底 complete，避免异常结束时 await 悬挂。
    for (final q in _approvalQueue) {
      if (!q.completer.isCompleted) q.completer.complete(false);
    }
    _approvalQueue.clear();
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
    if (_questionCompleter != null && !_questionCompleter!.isCompleted) {
      _questionCompleter!.complete(answer);
    }
    _questionCompleter = null;
    _pendingQuestion = null;
    notifyListeners();
  }

  Future<bool> askApproval(PendingApproval approval) {
    if (_cancelRequested) return Future.value(false);
    final completer = Completer<bool>();
    _approvalQueue.add(_QueuedApproval(approval, completer));
    _pumpApprovalQueue();
    return completer.future;
  }

  Future<String?> askUser(AgentQuestion question) {
    if (_cancelRequested) return Future.value(null);
    _pendingQuestion = question;
    _questionCompleter = Completer<String?>();
    notifyListeners();
    return _questionCompleter!.future;
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
