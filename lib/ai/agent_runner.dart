import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../fs/workspace_fs.dart';
import '../settings/settings_store.dart';
import '../version/checkpoint_store.dart';
import 'agent_client.dart';
import 'agent_tools.dart';
import 'chat_store.dart';
import 'context_compactor.dart';
import 'provider_config.dart';

/// Chat：纯对话不调工具；Agent：可读写文件与执行命令。
enum AgentMode { chat, agent }

/// 待审批项：文件写入 / 命令执行。
class PendingApproval {
  PendingApproval({
    required this.kind,
    required this.title,
    required this.detail,
    this.diffOld,
    this.diffNew,
    this.filePath,
  });

  final String kind;
  final String title;
  final String detail;
  final String? diffOld;
  final String? diffNew;
  final String? filePath;
}

class AgentQuestion {
  AgentQuestion({
    required this.question,
    required this.options,
  });

  final String question;
  final List<String> options;
}

/// 完整 Agent 循环（参考 Cline/Roo/Pi）：
/// 审批 + bash询问 + ask_question + 子Agent + 中断 + Plan/Act + 可配步数 + 上下文治理。
/// 操作审批策略：自动通过 / 提问 / 拒绝。
enum ApprovalAction { auto, ask, deny }

class AgentRunner extends ChangeNotifier {
  AgentRunner({
    required ChatStore chats,
    required CheckpointStore checkpoints,
    AgentClient? client,
    this.onFilesTouched,
  })  : _chats = chats,
        _checkpoints = checkpoints,
        _client = client ?? AgentClient();

  final ChatStore _chats;
  final CheckpointStore _checkpoints;
  final AgentClient _client;
  /// 写/删文件后刷新资源管理器与已打开编辑器；参数为相对路径列表。
  final void Function(List<String> paths)? onFilesTouched;

  bool _running = false;
  bool get running => _running;

  AgentMode mode = AgentMode.agent;
  int maxSteps = 25;
  int contextLimit = 20;
  int compactKeepRecent = 8;
  double compactTriggerRatio = 0.8;

  ApprovalAction approveCreateInside = ApprovalAction.auto;
  ApprovalAction approveCreateOutside = ApprovalAction.ask;
  ApprovalAction approveDelete = ApprovalAction.ask;
  ApprovalAction approveCommand = ApprovalAction.ask;

  // 上下文压缩状态
  bool _compacting = false;
  bool get compacting => _compacting;
  String? _lastCompactionSummary;
  String? get lastCompactionSummary => _lastCompactionSummary;
  int? _lastTokensBefore;
  int? _lastTokensAfter;
  int? get lastTokensBefore => _lastTokensBefore;
  int? get lastTokensAfter => _lastTokensAfter;

  // usage 校准系数：服务端 prompt_tokens / 本地估算
  double _usageCalibration = 1.0;
  double get usageCalibration => _usageCalibration;

  void setMode(AgentMode value) {
    mode = value;
    notifyListeners();
  }

  String? _streamContent;
  String? _streamReasoning;
  String? _currentTool;
  PendingApproval? _pendingApproval;
  AgentQuestion? _pendingQuestion;
  Completer<bool>? _approvalCompleter;
  Completer<String?>? _questionCompleter;
  bool _cancelRequested = false;

  String? get streamContent => _streamContent;
  String? get streamReasoning => _streamReasoning;
  String? get currentTool => _currentTool;
  PendingApproval? get pendingApproval => _pendingApproval;
  AgentQuestion? get pendingQuestion => _pendingQuestion;

  void requestCancel() {
    _cancelRequested = true;
    _approvalCompleter?.complete(false);
    _questionCompleter?.complete(null);
    notifyListeners();
  }

  void resolveApproval(bool approved) {
    _approvalCompleter?.complete(approved);
    _pendingApproval = null;
    notifyListeners();
  }

  void resolveQuestion(String? answer) {
    _questionCompleter?.complete(answer);
    _pendingQuestion = null;
    notifyListeners();
  }

  Future<bool> _askApproval(PendingApproval approval) {
    _pendingApproval = approval;
    _approvalCompleter = Completer<bool>();
    notifyListeners();
    return _approvalCompleter!.future;
  }

  Future<String?> _askUser(AgentQuestion question) {
    _pendingQuestion = question;
    _questionCompleter = Completer<String?>();
    notifyListeners();
    return _questionCompleter!.future;
  }

  List<Map<String, dynamic>>? _toolSchemas(AgentMode mode) {
    // Chat：纯对话，不挂任何工具。
    if (mode == AgentMode.chat) return null;
    return [
      {
        'type': 'function',
        'function': {
          'name': 'read_file',
          'description':
              '读取文件内容。工作区内用相对路径；用户附件若给出相对路径可直接读。工作区外用绝对路径（需审批）。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'limit': {'type': 'integer'},
              'offset': {'type': 'integer'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'list_files',
          'description':
              '列出目录内容。工作区内用相对路径（默认根目录）；用户附件文件夹可用其路径，区外绝对路径需审批。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'search_text',
          'description': '全文搜索。query 为关键词，include 可按后缀过滤如 .dart。',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'include': {'type': 'string'},
            },
            'required': ['query'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'ask_question',
          'description':
              '向用户提问以澄清需求。question 为问题，options 为候选答案列表。',
          'parameters': {
            'type': 'object',
            'properties': {
              'question': {'type': 'string'},
              'options': {
                'type': 'array',
                'items': {'type': 'string'}
              },
            },
            'required': ['question'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'spawn_subagent',
          'description':
              '派生子 Agent 处理独立子任务。task 为任务描述，files 为相关文件。子任务只读文件并返回摘要，不直接写文件。',
          'parameters': {
            'type': 'object',
            'properties': {
              'task': {'type': 'string'},
              'files': {
                'type': 'array',
                'items': {'type': 'string'}
              },
            },
            'required': ['task'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'write_file',
          'description':
              '新建或覆盖写文件。path 为相对路径，content 为完整内容。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'content': {'type': 'string'},
            },
            'required': ['path', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_file',
          'description':
              '精确文本替换。oldText 必须完全一致。执行前会弹窗请用户确认。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'oldText': {'type': 'string'},
              'newText': {'type': 'string'},
            },
            'required': ['path', 'oldText', 'newText'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_file',
          'description': '删除工作区内文件。path 为相对路径。默认会询问用户。',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'run_command',
          'description':
              '在工作区执行 shell 命令。白名单只读命令自动放行，其余弹窗确认，高危直接拒绝。',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
              'timeout': {'type': 'integer'},
            },
            'required': ['command'],
          },
        },
      },
    ];
  }

  String _systemPrompt(AgentMode mode, String? rootPath) {
    final base =
        '你是项目内的代码助手。工作区根目录为当前项目，文件路径使用相对路径。'
        '回复简洁中文。'
        '重要：不要在对话回复里粘贴完整源代码或大段代码块；'
        '代码只应通过工具写入文件。回复只说明改了哪些文件、做了什么变更。';
    if (mode == AgentMode.chat) {
      return '$base当前为【Chat 模式】：纯对话，不能调用任何工具，'
          '不要声称已读写文件或执行命令；需要改代码时请用户切换到 Agent。';
    }
    return '$base当前为【Agent 模式】：需要查看/修改文件时必须调用工具，不要臆测内容。'
        '修改文件必须使用 write_file / edit_file；仅在回复里贴代码不算真正更新。'
        '写文件与执行命令前系统会请用户确认。'
        '复杂任务可拆分子任务用 spawn_subagent 并行调研。';
  }

  /// 落盘前去掉 markdown 代码块，避免对话文件暴涨；改动看版本 diff。
  String _stripCodeBlocksForStorage(String text) {
    final stripped = text.replaceAllMapped(
      RegExp(r'```[\w+-]*\n[\s\S]*?```', multiLine: true),
      (m) => '（代码已写入文件，请点下方文件查看差异）',
    );
    return stripped.trim();
  }

  Future<void> run({
    required String sessionId,
    required String userText,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    int? maxSteps,
    List<String> imageDataUrls = const [],
  }) async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    _streamContent = '';
    _streamReasoning = '';
    _currentTool = null;
    _pendingApproval = null;
    _pendingQuestion = null;
    notifyListeners();

    final steps = maxSteps ?? this.maxSteps;
    try {
      final session =
          _chats.sessions.firstWhere((s) => s.id == sessionId);

      // 一轮对话只在结束后记一个版本；发送前的用户编辑由 UI 侧记 user-edit。
      await _chats.addMessage(ChatMessage(
        role: 'user',
        text: userText,
      ));

      // 上下文治理：超阈值先压缩，messages = [system, 摘要, 最近原文]
      final compactor = ContextCompactor(client: _client)
        ..triggerRatio = compactTriggerRatio
        ..keepRecent = compactKeepRecent;
      var historyForPrompt = _limitedHistory(session.messages);
      String? compactionSummary = session.compactionSummary;
      if (compactionSummary == null) {
        final probe = <Map<String, dynamic>>[
          {'role': 'system', 'content': _systemPrompt(mode, rootPath)},
          for (final m in historyForPrompt)
            if (m.role == 'user')
              {'role': 'user', 'content': m.text}
            else if (m.role == 'assistant')
              {'role': 'assistant', 'content': m.text},
        ];
        if (compactor.shouldCompact(
            messages: probe,
            model: model,
            calibration: _usageCalibration)) {
          _compacting = true;
          notifyListeners();
          try {
            final result = await compactor.compact(
              history: List<ChatMessage>.from(session.messages),
              provider: provider,
              model: model,
            );
            if (result.summary.isNotEmpty) {
              compactionSummary = result.summary;
              historyForPrompt = result.keptMessages;
              _lastCompactionSummary = result.summary;
              _lastTokensBefore = result.tokensBefore;
              _lastTokensAfter = result.tokensAfter;
              await _chats.saveCompaction(
                sessionId: sessionId,
                summary: result.summary,
                droppedCount: result.droppedCount,
              );
            }
          } catch (_) {
            // 压缩失败则退化为按条截断
          } finally {
            _compacting = false;
            notifyListeners();
          }
        }
      } else {
        // 已有摘要：只取最近 keepRecent 条原文
        final keep = compactKeepRecent;
        historyForPrompt = session.messages.length <= keep
            ? session.messages
            : session.messages
                .sublist(session.messages.length - keep);
      }

      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': _systemPrompt(mode, rootPath)
        },
        if (compactionSummary != null &&
            compactionSummary.isNotEmpty)
          {
            'role': 'system',
            'content': '【历史摘要】\n$compactionSummary'
          },
        for (final m in historyForPrompt)
          if (m.role == 'user')
            {'role': 'user', 'content': m.text}
          else if (m.role == 'assistant')
            {'role': 'assistant', 'content': m.text},
      ];
      // 当前用户消息若带图：替换最后一条 user 为 OpenAI image_url 多模态格式
      if (imageDataUrls.isNotEmpty && model.supportsVision) {
        for (var i = messages.length - 1; i >= 0; i--) {
          if (messages[i]['role'] == 'user') {
            final parts = <Map<String, dynamic>>[
              {'type': 'text', 'text': userText},
              for (final url in imageDataUrls)
                {
                  'type': 'image_url',
                  'image_url': {'url': url},
                },
            ];
            messages[i] = {'role': 'user', 'content': parts};
            break;
          }
        }
      }

      final touched = <String>[];
      var thinking = '';
      var reply = '';
      final tools =
          rootPath == null ? null : AgentTools(rootPath: rootPath);
      int? turnPromptTokens;
      int? turnCompletionTokens;

      for (var step = 0; step < steps; step++) {
        if (_cancelRequested) {
          reply += '\n\n（用户已中断）';
          break;
        }
        final contentBuf = StringBuffer();
        final reasoningBuf = StringBuffer();
        var pendingToolName = '';
        var pendingToolArgsStr = '';
        var pendingToolId = '';
        var hasToolCall = false;

        await for (final event in _client.streamChatWithTools(
          provider: provider,
          model: model,
          messages: messages,
          tools: tools == null ? null : _toolSchemas(mode),
        )) {
          if (_cancelRequested) break;
          if (event.content != null) {
            contentBuf.write(event.content);
            _streamContent = (_streamContent ?? '') + event.content!;
            notifyListeners();
          }
          if (event.reasoning != null) {
            reasoningBuf.write(event.reasoning);
            _streamReasoning =
                (_streamReasoning ?? '') + event.reasoning!;
            notifyListeners();
          }
          if (event.toolCall != null) {
            hasToolCall = true;
            pendingToolId = event.toolCall!.id;
            pendingToolName = event.toolCall!.name;
            pendingToolArgsStr =
                jsonEncode(event.toolCall!.arguments);
            _pendingToolArgs[event.toolCall!.id] =
                event.toolCall!.arguments;
          }
          if (event.promptTokens != null) {
            turnPromptTokens = event.promptTokens;
            final est =
                TokenEstimator.estimateMessages(messages);
            if (est > 0) {
              _usageCalibration =
                  (event.promptTokens! / est).clamp(0.5, 2.0);
            }
          }
          if (event.completionTokens != null) {
            turnCompletionTokens =
                (turnCompletionTokens ?? 0) + event.completionTokens!;
          }
          if (event.done) break;
        }
        if (_cancelRequested) {
          reply += contentBuf.toString();
          thinking += reasoningBuf.toString();
          break;
        }

        final stepText = contentBuf.toString();
        final stepReasoning = reasoningBuf.toString();
        if (stepText.isNotEmpty) {
          reply += stepText;
          messages.add({'role': 'assistant', 'content': stepText});
        }
        if (stepReasoning.isNotEmpty) thinking += stepReasoning;
        if (!hasToolCall || tools == null) break;

        final args =
            _pendingToolArgs[pendingToolId] ?? <String, dynamic>{};
        final toolResult = await _executeToolWithGuards(
          toolName: pendingToolName,
          args: args,
          provider: provider,
          model: model,
          rootPath: rootPath,
          sessionId: sessionId,
        );
        if (_cancelRequested) break;
        if (toolResult == null) {
          // 被用户拒绝
          messages.add({
            'role': 'assistant',
            'content': stepText.isEmpty ? '' : stepText,
            'tool_calls': [
              {
                'id': pendingToolId,
                'type': 'function',
                'function': {
                  'name': pendingToolName,
                  'arguments': pendingToolArgsStr,
                },
              }
            ],
          });
          messages.add({
            'role': 'tool',
            'tool_call_id': pendingToolId,
            'name': pendingToolName,
            'content': '用户拒绝了该操作，已跳过。',
          });
          reply += '\n\n（该操作被用户拒绝，已跳过）';
          continue;
        }
        touched.addAll(toolResult.touchedFiles);

        messages.add({
          'role': 'assistant',
          'content': stepText.isEmpty ? '' : stepText,
          'tool_calls': [
            {
              'id': pendingToolId,
              'type': 'function',
              'function': {
                'name': pendingToolName,
                'arguments': pendingToolArgsStr,
              },
            }
          ],
        });
        messages.add({
          'role': 'tool',
          'tool_call_id': pendingToolId,
          'name': pendingToolName,
          'content': toolResult.output,
        });
      }

      // 有文件改动才记版本；纯闲聊不产生版本节点。
      String? afterId;
      final uniqueTouched =
          touched.where((p) => !p.endsWith('.DS_Store')).toSet().toList();
      if (uniqueTouched.isNotEmpty) {
        try {
          final cp = await _checkpoints.checkpoint(
            message:
                'AI 改动 ${uniqueTouched.take(3).join(', ')}${uniqueTouched.length > 3 ? ' 等' : ''}',
            kind: 'ai-edit',
            chatId: sessionId,
          );
          afterId = cp?.id;
        } catch (_) {}
        onFilesTouched?.call(uniqueTouched);
      }

      final contextLimit = model.contextLength ?? 128000;
      final contextUsed = turnPromptTokens ??
          (TokenEstimator.estimateMessages(messages) * _usageCalibration)
              .round();
      final completionTokens = turnCompletionTokens ??
          TokenEstimator.estimate(reply + thinking);
      var displayReply = reply.isEmpty
          ? '（模型无文本回复，请查看工具执行结果）'
          : _stripCodeBlocksForStorage(reply);
      if (uniqueTouched.isEmpty &&
          mode == AgentMode.agent &&
          RegExp(r'```').hasMatch(reply)) {
        displayReply =
            '$displayReply\n\n⚠️ 本轮未通过工具写入文件，因此没有可回退的文件差异。'
            '若要真正改文件，请再发一次并让我调用 write_file/edit_file。';
      }
      var fileList = uniqueTouched;
      if (fileList.isEmpty && afterId != null) {
        try {
          final changes = await _checkpoints.changesOf(afterId);
          fileList = changes
              .map((c) => c.path)
              .where((p) => !p.endsWith('.DS_Store'))
              .toList();
        } catch (_) {}
      }
      await _chats.addMessage(ChatMessage(
        role: 'assistant',
        text: displayReply,
        thinking: thinking.isEmpty ? null : thinking,
        files: fileList,
        afterVersionId: afterId,
        promptTokens: turnPromptTokens ?? contextUsed,
        completionTokens: completionTokens,
        contextUsed: contextUsed,
        contextLimit: contextLimit,
      ));
    } catch (e) {
      await _chats.addMessage(ChatMessage(
        role: 'assistant',
        text: '请求失败：$e',
      ));
    } finally {
      _running = false;
      _cancelRequested = false;
      _streamContent = null;
      _streamReasoning = null;
      _currentTool = null;
      _pendingApproval = null;
      _pendingQuestion = null;
      notifyListeners();
    }
  }

  /// 返回 null 表示被用户拒绝；抛错表示失败。
  Future<AgentToolResult?> _executeToolWithGuards({
    required String toolName,
    required Map<String, dynamic> args,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String? rootPath,
    required String sessionId,
  }) async {
    if (rootPath == null) {
      return AgentToolResult(ok: false, output: '未打开工作区');
    }
    final tools = AgentTools(rootPath: rootPath);

    switch (toolName) {
      case 'read_file':
      case 'list_files':
      case 'search_text':
        // 读操作：区内直放，区外/敏感走审批后真实读取
        final readPath = '${args['path'] ?? '.'}';
        final readZone = tools.fs.zoneOf(readPath);
        if (readZone != FsZone.inside) {
          if (toolName == 'search_text') {
            return AgentToolResult(
              ok: false,
              output: 'search_text 仅支持工作区内；区外请用 read_file / list_files',
            );
          }
          final approved = await _askApproval(PendingApproval(
            kind: 'file-read',
            title: readZone == FsZone.sensitive
                ? '读取敏感路径'
                : '读取工作区外路径',
            detail:
                '$toolName $readPath\n${readZone == FsZone.sensitive ? '该路径涉及密钥/可执行配置，' : ''}允许本次读取吗？',
            filePath: readPath,
          ));
          if (!approved || _cancelRequested) return null;
          _currentTool = '正在执行 $toolName';
          notifyListeners();
          final outsideResult =
              await tools.executeApprovedRead(toolName, args);
          _currentTool = null;
          notifyListeners();
          return outsideResult;
        }
        _currentTool = '正在执行 $toolName';
        notifyListeners();
        final result = await tools.execute(toolName, args);
        _currentTool = null;
        notifyListeners();
        return result;

      case 'write_file':
      case 'edit_file':
      case 'delete_file':
        if (mode == AgentMode.chat) {
          return AgentToolResult(
              ok: false,
              output: 'Chat 模式禁止写文件，请切换到 Agent');
        }
        final writePath = '${args['path'] ?? ''}';
        final writeZone = tools.fs.zoneOf(writePath);
        final isDelete = toolName == 'delete_file';
        final preview = isDelete
            ? await tools.preview(toolName, args)
            : await tools.preview(toolName, args);
        if (!preview.ok) return preview;
        if (!isDelete && preview.preview == null) return preview;

        final ApprovalAction policy;
        if (isDelete) {
          policy = approveDelete;
        } else if (writeZone == FsZone.inside) {
          policy = approveCreateInside;
        } else {
          policy = approveCreateOutside;
        }

        final zoneLabel = writeZone == FsZone.inside
            ? ''
            : writeZone == FsZone.sensitive
                ? '（敏感路径）'
                : '（工作区外）';
        final title = isDelete
            ? '删除文件$zoneLabel'
            : '${toolName == 'write_file' ? '写入文件' : '编辑文件'}$zoneLabel';
        final approved = await _shouldProceed(
          policy,
          PendingApproval(
            kind: isDelete ? 'file-delete' : 'file',
            title: title,
            detail: isDelete
                ? '$writePath\n${preview.output}'
                : '${preview.preview!.path}\n${preview.output}',
            diffOld: preview.preview?.oldContent,
            diffNew: preview.preview?.newContent,
            filePath: preview.preview?.path ?? writePath,
          ),
        );
        if (!approved || _cancelRequested) return null;
        _currentTool = isDelete
            ? '正在删除 $writePath'
            : '正在${toolName == 'write_file' ? '写入' : '编辑'} ${preview.preview!.path}';
        notifyListeners();
        final applied = await tools.execute(toolName, args);
        if (applied.ok && applied.touchedFiles.isNotEmpty) {
          onFilesTouched?.call(applied.touchedFiles);
        }
        _currentTool = null;
        notifyListeners();
        return applied;

      case 'run_command':
        final command = '${args['command'] ?? ''}';
        final verdict = CommandPolicy.judge(command);
        if (verdict == CommandVerdict.deny ||
            AgentTools.isDangerous(command) ||
            approveCommand == ApprovalAction.deny) {
          return AgentToolResult(
              ok: false, output: '拒绝执行命令：$command');
        }
        // 设置「提问」→ 一律询问；「自动」→ 仅非白名单询问
        final action = approveCommand == ApprovalAction.auto &&
                (verdict == CommandVerdict.allow ||
                    AgentTools.isSafeCommand(command))
            ? ApprovalAction.auto
            : ApprovalAction.ask;
        final approved = await _shouldProceed(
          action,
          PendingApproval(
            kind: 'command',
            title: '执行命令',
            detail: '\$ $command\n工作区：$rootPath',
          ),
        );
        if (!approved || _cancelRequested) return null;
        _currentTool = '正在执行 \$ $command';
        notifyListeners();
        final cmdResult = await tools.execute(toolName, args);
        if (cmdResult.ok) {
          onFilesTouched?.call(cmdResult.touchedFiles);
        }
        _currentTool = null;
        notifyListeners();
        return cmdResult;

      case 'ask_question':
        final question = '${args['question'] ?? ''}';
        final options = ((args['options'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        final answer = await _askUser(AgentQuestion(
          question: question.isEmpty ? '请补充信息' : question,
          options: options,
        ));
        if (answer == null || _cancelRequested) return null;
        return AgentToolResult(
            ok: true, output: '用户回答：$answer');

      case 'spawn_subagent':
        final task = '${args['task'] ?? ''}';
        final files = ((args['files'] as List?) ?? [])
            .map((e) => '$e')
            .toList();
        return _runSubagent(
          task: task,
          files: files,
          provider: provider,
          model: model,
          rootPath: rootPath,
        );

      default:
        return AgentToolResult(
            ok: false, output: '未知工具：$toolName');
    }
  }

  /// 子 Agent：只读调研，独立上下文，最多 6 步，只返回摘要。
  Future<AgentToolResult> _runSubagent({
    required String task,
    required List<String> files,
    required AiProviderConfig provider,
    required AiModelOption model,
    required String rootPath,
  }) async {
    _currentTool = '子 Agent 调研中：$task';
    notifyListeners();
    try {
      final tools = AgentTools(rootPath: rootPath);
      var context = '你是子 Agent，只做只读调研并返回摘要，不要写文件。\n';
      if (files.isNotEmpty) {
        context += '相关文件：${files.join(', ')}\n';
        for (final f in files.take(5)) {
          final r = await tools.execute('read_file', {'path': f});
          if (r.ok) context += '\n--- $f ---\n${r.output}\n';
        }
      }
      final messages = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': context},
        <String, dynamic>{'role': 'user', 'content': task},
      ];
      final buf = StringBuffer();
      var steps = 0;
      var keepGoing = true;
      while (keepGoing && steps < 6 && !_cancelRequested) {
        steps++;
        keepGoing = false;
        await for (final event in _client.streamChatWithTools(
          provider: provider,
          model: model,
          messages: messages,
          tools: [
            {
              'type': 'function',
              'function': {
                'name': 'read_file',
                'description': '读取文件',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'path': {'type': 'string'}
                  },
                  'required': ['path'],
                },
              },
            },
            {
              'type': 'function',
              'function': {
                'name': 'search_text',
                'description': '搜索文本',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'query': {'type': 'string'}
                  },
                  'required': ['query'],
                },
              },
            },
          ],
        )) {
          if (_cancelRequested) break;
          if (event.content != null) buf.write(event.content);
          if (event.toolCall != null) {
            final r = await tools.execute(
                event.toolCall!.name, event.toolCall!.arguments);
            messages.add(<String, dynamic>{
              'role': 'assistant',
              'content': '',
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': event.toolCall!.id,
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': event.toolCall!.name,
                    'arguments':
                        jsonEncode(event.toolCall!.arguments),
                  },
                }
              ],
            });
            messages.add({
              'role': 'tool',
              'tool_call_id': event.toolCall!.id,
              'name': event.toolCall!.name,
              'content': r.output,
            });
            keepGoing = true;
          }
          if (event.done) break;
        }
      }
      final summary = buf.toString().trim();
      return AgentToolResult(
        ok: true,
        output: '子 Agent 摘要：\n${summary.isEmpty ? '（无输出）' : summary}',
      );
    } finally {
      _currentTool = null;
      notifyListeners();
    }
  }

  final Map<String, Map<String, dynamic>> _pendingToolArgs = {};

  List<ChatMessage> _limitedHistory(List<ChatMessage> messages) {
    // 上下文治理：按条数截断，可在设置调
    if (messages.length <= contextLimit) return messages;
    return messages.sublist(messages.length - contextLimit);
  }

  void loadSettings(SettingsStore settings) {
    maxSteps =
        (settings.getInt('agentMaxSteps') ?? 25).clamp(1, 100);
    contextLimit =
        (settings.getInt('agentContextLimit') ?? 20).clamp(4, 100);
    compactKeepRecent =
        (settings.getInt('agentCompactKeep') ?? 8).clamp(2, 20);
    final pct = settings.getInt('agentCompactRatioPct') ?? 80;
    compactTriggerRatio = (pct.clamp(50, 95) / 100.0);
    final modeStr = settings.getString('agentMode') ?? 'agent';
    // 兼容旧值 plan/act
    mode = (modeStr == 'chat' || modeStr == 'plan')
        ? AgentMode.chat
        : AgentMode.agent;
    approveCreateInside = _parseApproval(
        settings.getString('approveCreateInside'), ApprovalAction.auto);
    approveCreateOutside = _parseApproval(
        settings.getString('approveCreateOutside'), ApprovalAction.ask);
    approveDelete = _parseApproval(
        settings.getString('approveDelete'), ApprovalAction.ask);
    approveCommand = _parseApproval(
        settings.getString('approveCommand'), ApprovalAction.ask);
    notifyListeners();
  }

  static ApprovalAction _parseApproval(String? raw, ApprovalAction fallback) {
    switch (raw) {
      case 'auto':
        return ApprovalAction.auto;
      case 'deny':
        return ApprovalAction.deny;
      case 'ask':
        return ApprovalAction.ask;
      default:
        return fallback;
    }
  }

  Future<bool> _shouldProceed(
      ApprovalAction action, PendingApproval approval) async {
    switch (action) {
      case ApprovalAction.auto:
        return true;
      case ApprovalAction.deny:
        return false;
      case ApprovalAction.ask:
        return _askApproval(approval);
    }
  }
}
