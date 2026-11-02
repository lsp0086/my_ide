import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_logger.dart';
import 'remote_channel.dart' show clipRunes;

part 'chat_store_models.dart';
part 'chat_store_assets.dart';
part 'chat_store_lifecycle.dart';
part 'chat_store_turn.dart';
part 'chat_store_revert.dart';

class ChatStore extends ChangeNotifier {
  final List<ChatSession> _sessions = [];
  String? _activeId;
  String? _projectRoot;
  int _loadGeneration = 0;
  String? _lastSaveError;
  bool _dirty = false;
  // R9：会话删除通知钩子——AgentRunner 挂载后在此登记 dropSessionState，
  // deleteChat/clearChats/clearAll/loadForProject 切项目时同步清运行时残留
  // （Runner 侧排队桶/流式态/命令轨迹、Gate 审批队列/信任桶、Registry 分账）。
  // 钩子一律 try/catch 包裹，清理失败不阻断删除主流程。
  final List<Future<void> Function(String sessionId)> _sessionDropHooks = [];

  // dispose 后守卫：解锁触发的自动补载是 fire-and-forget 异步，
  // 可能与 store 释放竞速，notifyListeners 不得在 dispose 后调用。
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// 运行锁：AgentRunner.run() 起止之间锁定会话，防回退/删除与
  /// 运行中遍历（预算计算/responseId 反查）竞争导致长度突变或索引越界。
  /// UI 层已有 runner.running 守卫，此处为 store 侧强制防线。
  /// runner 自身写压缩需放行：加 [internal] 旁路。
  final Set<String> _lockedSessions = {};
  void lockSession(String sessionId) => _lockedSessions.add(sessionId);

  /// 运行锁期间收到过的切项目/关项目请求：最后一个锁释放后需补载的目标根。
  /// 此前锁定期间 loadForProject 只更新 _projectRoot 不动会话列表，
  /// 内存（旧项目会话）与 _projectRoot（新项目）错位，_save 会把旧项目
  /// 会话写进新项目 .my_ide/chats，跨项目污染。
  String? _pendingReloadRoot;
  void unlockSession(String sessionId) {
    _lockedSessions.remove(sessionId);
    // 最后一个运行锁释放且有挂起的切项目请求：自动补载目标项目。
    if (_lockedSessions.isEmpty && _pendingReloadRoot != null) {
      final root = _pendingReloadRoot;
      _pendingReloadRoot = null;
      if (root != _projectRoot) {
        // A17：补载是“尽力而为”的后台动作，此处 await 不接异常会变成
        // 未捕获异步错误（unlockSession 本身是同步 void）。失败静默降级，
        // 用户手动重开项目仍可恢复。
        unawaited(
          loadForProject(root).catchError((Object e, StackTrace st) {
            AppLogger.instance.error('chat', '切项目补载失败', e);
            _lastSaveError = '切项目补载失败：$e';
            notifyListeners();
          }),
        );
      }
    }
  }

  bool isSessionLocked(String sessionId) => _lockedSessions.contains(sessionId);

  String? get projectRoot => _projectRoot;

  /// 解析图片引用为 dataUrl：`asset:` 走磁盘读文件，新 dataUrl 直接透传。
  /// 文件缺失返回 null，调用方跳过该图不中断整轮。
  Future<String?> resolveChatImage(String ref) async {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.startsWith('asset:')) return trimmed;
    final root = _projectRoot;
    if (root == null) return null;
    final rel = trimmed.substring('asset:'.length).trim();
    // B11：规范化 + isWithin 门禁 + 拒 symlink，不只拦 `..`。
    if (rel.isEmpty) return null;
    final normRel = p.normalize(rel).replaceAll('\\', '/');
    if (!normRel.startsWith('chat_assets/')) return null;
    try {
      final base = p.normalize(p.join(root, '.my_ide'));
      final abs = p.normalize(p.join(base, rel));
      if (abs != base && !p.isWithin(base, abs)) return null;
      if (FileSystemEntity.typeSync(abs, followLinks: false) ==
          FileSystemEntityType.link) {
        return null;
      }
      final file = File(abs);
      if (!await file.exists()) return null;
      if (await file.length() > 8 * 1024 * 1024) return null;
      final bytes = await file.readAsBytes();
      final mime = _guessImageMime(rel, bytes);
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  /// 批量解析图片引用，缺失/超限的图直接丢弃（至少保留文本不中断）。
  Future<List<String>> resolveChatImages(List<String> refs) async {
    final out = <String>[];
    for (final ref in refs) {
      final url = await resolveChatImage(ref);
      if (url != null && url.isNotEmpty) out.add(url);
    }
    return out;
  }

  /// R8-A1 魔数双认（测试可见）：后缀可伪造，mime 必须与文件头一致。
  static bool imageMagicMatchesForTest(String mime, List<int> bytes) =>
      _imageMagicMatches(mime, bytes);


  /// G2-7（对齐 OpenHands archive）：会话列表默认过滤已归档会话，
  /// 现有调用点（会话 Tab/列表/远控 /sessions）无需改动即隐藏归档条目。
  List<ChatSession> get sessions =>
      List.unmodifiable(_sessions.where((s) => !s.archived));

  /// 已归档会话快照：供“显示已归档”切换与恢复入口。
  List<ChatSession> get archivedSessions =>
      List.unmodifiable(_sessions.where((s) => s.archived));

  String? get lastSaveError => _lastSaveError;
  bool get dirty => _dirty;
  ChatSession? get active {
    for (final s in _sessions) {
      if (s.id == _activeId) return s;
    }
    return null;
  }


  /// LLM 自动标题占位：首句截断 20 字；模型生成由 Runner 首轮后调用，失败回退。
  static String generateTitle(String text) {
    final first = text
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
        .trim();
    if (first.isEmpty) return '新对话';
    const max = 20;
    // D6-L15：截断改按 rune——substring 按 UTF-16 码元切，emoji/生僻字
    // 标题落边界即被拦腰切成乱码（C10 口径，applyGeneratedTitle 已如此）。
    return first.runes.length > max ? '${clipRunes(first, max)}…' : first;
  }


  // A22：searchSessions 零调用已删除（会话搜索 UI 未接线）。

}
