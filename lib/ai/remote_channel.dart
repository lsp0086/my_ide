/// IM 平台（CodingTo types.go Platform 对标，来源
/// https://github.com/ShimmerTo/CodingTo ）。
/// IM 只做指令/审批/回传面，不做手机投屏触控面；密钥走 SecretVault。
/// C12：wecom 枚举全库零实现零引用（无连接器、无 switch 分支），删除。
enum RemotePlatform {
  feishu,
  dingtalk,
}

/// C10：按 rune 截断的统一辅助——String.substring 按 UTF-16 码元切，
/// 中文/emoji 会被拦腰切断成乱码；所有面向日志/摘要的截断统一走这里。
String clipRunes(String s, int maxRunes) {
  if (maxRunes <= 0) return '';
  if (s.runes.length <= maxRunes) return s;
  return String.fromCharCodes(s.runes.take(maxRunes));
}

/// 入站归一消息（CodingTo InboundMessage 对标）。
class RemoteInbound {
  RemoteInbound({
    required this.channelId,
    required this.platform,
    required this.senderId,
    required this.threadId,
    required this.text,
    this.messageId = '',
    this.receiveIdType = '',
  });

  final int channelId;
  final RemotePlatform platform;
  final String senderId;
  final String threadId;
  final String text;
  final String messageId;
  final String receiveIdType;
}

/// 出站归一消息（CodingTo OutboundMessage 对标）。
class RemoteOutbound {
  RemoteOutbound({
    required this.threadId,
    required this.text,
    this.receiveIdType = '',
    this.replyToMessageId = '',
    this.confirm = false,
    this.title = '',
  });

  final String threadId;
  final String text;
  final String receiveIdType;
  final String replyToMessageId;

  /// 审批卡片：true=二选一确认卡（CodingTo CardPayload.Confirm 对标），
  /// IM 侧回「确认/拒绝」。
  final bool confirm;
  final String title;
}

/// B4：IM 卡片交互回调（飞书 card.action.trigger / 钉钉
/// CardCallbackMessage）——审批按钮化的入站面。连接器实现
/// [CardActionConnector] 即支持；value 为按钮自定义负载（如
/// {'action':'confirm'|'reject', 'approvalId': ''}），token/messageId 用于
/// 3 秒内回执（toast/更新卡片）。
class RemoteCardAction {
  RemoteCardAction({
    required this.platform,
    required this.threadId,
    required this.operatorId,
    required this.value,
    this.token = '',
    this.messageId = '',
  });

  final RemotePlatform platform;

  /// 会话（群/单聊）id：决议与提醒按会话归属。
  final String threadId;
  final String operatorId;

  /// 按钮自定义负载（map）：约定 {'action': 'confirm'|'reject'} 供 steward
  /// 决议人审；其余原样回灌路由（斜杠命令/任务文本）。
  final Map<String, dynamic> value;

  /// 回调票据：飞书 toast 回执用（钉钉为 ACK 帧 messageId）。
  final String token;
  final String messageId;

  /// 便捷决议判定：value.action 为 confirm/reject 才返回值，否则 null。
  bool? get decision {
    final a = '${value['action'] ?? ''}'.trim().toLowerCase();
    if (a == 'confirm' || a == 'approve' || a == 'accept') return true;
    if (a == 'reject' || a == 'deny' || a == 'cancel') return false;
    return null;
  }
}

/// B4：支持卡片交互回调的连接器（可选能力）——steward 检测到即接线，
/// 未实现不影响既有文本决议链路。
abstract class CardActionConnector {
  void onCardAction(void Function(RemoteCardAction action) handler);

  /// 回调回执：toast 提示（飞书 3 秒内必须响应之一；钉钉为 ACK 帧数据）。
  Future<void> respondCardAction(
    RemoteCardAction action, {
    required String toastType,
    required String content,
  });
}

/// 渠道连接器抽象（CodingTo Connector 对标）：
/// Connect 建长连接、Send 并发安全、Close 幂等。
abstract class RemoteConnector {
  Future<void> connect(void Function() ready);
  Future<void> send(RemoteOutbound msg);
  Future<void> close();
}

/// 远控任务（CodingTo BotTask/store.BotTask 对标）：
/// 会话绑定 + 状态机，重启可按 sessionId 恢复映射。
class RemoteTask {
  RemoteTask({
    required this.id,
    required this.threadId,
    required this.sessionId,
    required this.brief,
    this.status = 'running',
    this.result = '',
  });

  final String id;
  // C12：channelId 与 platform 冗余且全库零读取，字段与构造赋值一并删除。
  // D6-L14：platform/senderId 复查仍零读取（仅 remote_steward 赋值），
  // 一并删除；channelId 因非本域测试文件仍引用其构造参数，保留待中央协调。
  final String threadId;
  final String sessionId;
  final String brief;
  String status;
  String result;

  /// C15：/stop 处置标记——置位后在途回合完成时不得回写 finished/结果，
  /// 防止 run 收尾覆盖「已由远控结束」的停机语义。
  bool stopped = false;

  bool get finished => status == 'finished' || status == 'failed';
}

/// 斜杠命令（CodingTo commands.go 对标）：Go 规则免 LLM，
/// /help//sessions//stop//task 先行（/env 需环境概念暂不做）。
class RemoteCommands {
  static bool isCommand(String text) => text.trimLeft().startsWith('/');

  static String commandOf(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '';
    return parts.first.toLowerCase();
  }

  static List<String> argsOf(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.length <= 1) return const [];
    return parts.sublist(1);
  }

  static bool isKnown(String cmd) => cmd == '/help' || cmd == '/sessions' ||
      cmd == '/running' || cmd == '/stop' || cmd == '/task' ||
      cmd == '/send';

  static String helpText() => '''可用命令：
/help             帮助
/sessions         查看所有对话
/running          查看进行中的对话
/stop <会话id>    结束对话
/task <会话id>    查看任务详情
/send <会话id> <消息>
                  向已有会话发新消息并回传结果
其他消息将交给管家 Agent 处理。''';

  /// 审批文本决议（CodingTo permission.go recognizedPermissionAnswer
  /// confirm 分支对标）：确认/拒绝两类匹配。
  /// R-CONFIRM-SCOPE：前缀匹配收窄——此前以 `y`/`n`/`ok`/`是` 等开头的
  /// 任意英文句子（"now continue..."、"yeah go ahead"）会被误当决议，
  /// 闲聊误触发审批。现：单字符仅接受整条消息恰为该字符；
  /// 多字词需整词边界匹配（词后非字母数字）。
  static bool? confirmAnswer(String raw) {
    final lower = raw.trim().toLowerCase();
    if (lower.isEmpty) return null;
    // D6-M11：疑问句式排除——"是否/能否/是不是…"以"是/否"开头，会被
    // 下方前缀匹配误判为确认/拒绝决议（"是否要关机？"触发放行=危险
    // 误批）。疑问句一律不决议，走任务/闲聊路径。
    const interrogatives = [
      '是否', '能否', '能不能', '可不可以', '是不是', '要不要', '该不该',
    ];
    for (final q in interrogatives) {
      if (lower.startsWith(q)) return null;
    }
    // 单字符快捷决议：整条消息恰为 y/n 才生效。
    if (lower == 'y') return true;
    if (lower == 'n') return false;
    const yes = [
      '确认', '批准', '通过', '同意', '允许', '是', 'yes', 'ok',
      'allow', 'approve', 'confirm', 'accept',
    ];
    const no = [
      '拒绝', '取消', '否', 'no', 'deny', 'cancel', 'reject',
      '不同意', '不允许',
    ];
    for (final w in no) {
      if (_matchesWholeWord(lower, w)) return false;
    }
    for (final w in yes) {
      if (_matchesWholeWord(lower, w)) return true;
    }
    return null;
  }

  /// 中文词前缀即可（无词边界概念）；英文需整词（后随非字母数字）。
  static bool _matchesWholeWord(String lower, String word) {
    if (!lower.startsWith(word)) return false;
    if (RegExp(r'[a-z]').hasMatch(word)) {
      final rest = lower.substring(word.length);
      if (rest.isNotEmpty && RegExp(r'^[a-z0-9]').hasMatch(rest)) {
        return false;
      }
      return true;
    }
    return true;
  }

  /// 出站分片（CodingTo message.go messageSplitRunes=2000 对标）：
  /// 飞书/钉钉按 rune 拆，标题优先断段、代码围栏与表格尽量不断中。
  ///
  /// S3-7：围栏配对——扫描行时跟踪 ``` 开关（inFence）：围栏内不因标题/容量
  /// 主动断段；若围栏内行导致超限，先把未闭合的 ``` 补闭合到当前片、
  /// 下片以原开头行（含语言标注）重新开围栏，保证每片内 ``` 计数为偶数。
  static List<String> splitOutbound(String text, {int maxRunes = 2000}) {
    if (maxRunes <= 0) return [text];
    if (text.runes.length <= maxRunes) return [text];
    final lines = text.split('\n');
    final parts = <String>[];
    final buf = <String>[];
    var size = 0;
    // S3-7：围栏状态——inFence 表示 buf 尚有未闭合的 ```；fenceOpener 记
    // 原开头行（如 ```dart），断段后下片用它重开。
    var inFence = false;
    var fenceOpener = '```';

    void flush() {
      if (buf.isEmpty) return;
      if (inFence) {
        // 围栏内断段：补闭合到当前片，下片重开围栏（配对不破坏）。
        buf.add('```');
        parts.add(buf.join('\n'));
        buf
          ..clear()
          ..add(fenceOpener);
        size = fenceOpener.runes.length + 1;
        return;
      }
      parts.add(buf.join('\n'));
      buf.clear();
      size = 0;
    }

    for (final line in lines) {
      final ls = line.runes.length + 1;
      final isFenceEdge = line.trimLeft().startsWith('```');
      // 围栏开关在本行入 buf 时切换：断段判定先按「本行未入 buf」的旧状态，
      // 保证收尾围栏行不被留在未闭合片外。
      // 标题另起一段（CodingTo heading 章节边界对标；围栏内不断）。
      if (!inFence && line.startsWith('# ') && buf.isNotEmpty) flush();
      if (ls > maxRunes) {
        flush();
        // 超长单行按 rune 硬切（围栏内硬切片不带围栏，``` 计数为 0 仍配对）。
        final runes = line.runes.toList();
        var i = 0;
        while (i < runes.length) {
          final j = (i + maxRunes < runes.length) ? i + maxRunes : runes.length;
          parts.add(String.fromCharCodes(runes.sublist(i, j)));
          i = j;
        }
        continue;
      }
      if (size + ls > maxRunes && buf.isNotEmpty) {
        if (inFence && isFenceEdge) {
          // 收尾围栏行恰逢超限：直接入片（差几个 rune），避免「闭合后立即
          // 重开」的空码块。
          inFence = false;
          buf.add(line);
          size += ls;
          continue;
        }
        flush();
      }
      if (isFenceEdge) {
        if (!inFence) {
          fenceOpener = line;
          inFence = true;
        } else {
          inFence = false;
        }
      }
      buf.add(line);
      size += ls;
    }
    // 文本在围栏内结束：补闭合保证末片配对。
    flush();
    return parts.isEmpty ? [text] : parts;
  }

  /// 结果回传拼装（CodingTo report.go composeResult 对标）：
  /// ✅/❌ + 对话ID + 任务摘要 + 末条 assistant 文本。
  static String composeResult({
    required String sessionId,
    required String brief,
    required String finalText,
    required bool failed,
    String error = '',
  }) {
    final lines = <String>['💬 对话ID：$sessionId'];
    final b = brief.trim();
    if (b.isNotEmpty) {
      final runes = b.runes.toList();
      lines.add('📋 任务：${runes.length > 100 ? '${String.fromCharCodes(runes.sublist(0, 100))}…' : b}');
    }
    if (failed) {
      lines.add('❌ 任务失败');
      final e = error.trim().isNotEmpty ? error.trim() : finalText.trim();
      if (e.isNotEmpty) lines.add(e);
    } else {
      lines.add('✅ 任务完成');
      if (finalText.trim().isNotEmpty) lines.add(finalText.trim());
    }
    final out = lines.join('\n').trim();
    return out.isEmpty ? '✅ 任务完成' : out;
  }
}
