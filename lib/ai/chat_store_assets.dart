part of 'chat_store.dart';

/// 图片资产域：dataUrl 落盘资产化、引用解析、长度探针、清理与分叉复制。
extension ChatStoreAssets on ChatStore {
  /// 对话图片资产目录：`[root]/.my_ide/chat_assets/[sessionId]/img-[ts]-[rand].[ext]`。
  /// dataUrl 仅内存传输，落盘一律转独立文件引用 `asset:<相对路径>`，
  /// 避免 5MB base64 反复进出 chats/*.json 压爆体积。
  Future<String> saveChatImageAsset({
    required String sessionId,
    required List<int> bytes,
    required String mime,
  }) async {
    final root = _projectRoot;
    if (root == null) throw StateError('未打开项目，图片无法落盘');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sessionId)) {
      throw StateError('会话 id 非法，图片已拒绝');
    }
    // R8-A1：mime 白名单+大小上限——_parseChatImageDataUrl 只认 image/ 前缀，
    // image/svg+xml 等可执行载荷此前直落盘、同目录 .my_ide 下可被 file:// 读走
    // 成 XSS 跳板；超大字节此前只在解析侧限 8MB，save 直调可绕过。现白名单
    // 5 种位图+mime 与魔数双认（后缀可伪造），超 8MB 直接拒。
    final normMime = mime.trim().toLowerCase().split(';').first;
    const allowed = {
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
      'image/bmp',
    };
    if (!allowed.contains(normMime)) {
      throw StateError('不支持的图片类型，已拒绝：$mime');
    }
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('图片过大或为空，已拒绝（上限 8MB）');
    }
    if (!_imageMagicMatches(normMime, bytes)) {
      throw StateError('图片魔数与类型不符，已拒绝：$mime');
    }
    final ext = normMime == 'image/jpeg'
        ? 'jpg'
        : normMime == 'image/gif'
        ? 'gif'
        : normMime == 'image/webp'
        ? 'webp'
        : normMime == 'image/bmp'
        ? 'bmp'
        : 'png';
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = _ChatCodec.newId().split('-').last;
    final rel = p.join('chat_assets', sessionId, 'img-$stamp-$rand.$ext');
    // A2-6：写文件与删目录共用"会话资产目录"key 串行——删除在途时本任务
    // 排队等删完再写（孤图由随后清理或下轮删除回收），不再并发复活目录。
    // 同时加会话存临门校验：删除已把会话摘出 _sessions 时直接拒写。
    if (!_sessions.any((e) => e.id == sessionId)) {
      throw StateError('会话已删除，图片未落盘');
    }
    final assetKey = p.join(root, '.my_ide', 'chat_assets', sessionId);
    await _ChatCodec.enqueueKey(assetKey, () async {
      final file = File(p.join(root, '.my_ide', rel));
      await file.parent.create(recursive: true);
      // B11：原子写 + 同名不覆盖（stamp+rand 碰撞时换名重试），崩溃不留半张图。
      var target = file;
      for (var i = 0; i < 3 && await target.exists(); i++) {
        final retry = _ChatCodec.newId().split('-').last;
        target = File(
          p.join(
            root,
            '.my_ide',
            p.join('chat_assets', sessionId, 'img-$stamp-$retry.$ext'),
          ),
        );
      }
      // A8：3 次换名重试耗尽仍撞名则抛错拒写——此前直接覆盖同名旧图，
      // 引用同一资产的旧消息图被静默换内容（幽灵替换）。
      if (await target.exists()) {
        throw StateError('图片名冲突，已拒绝覆盖：${p.basename(target.path)}');
      }
      final tmp = File('${target.path}.${_ChatCodec.newId()}.tmp');
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        try {
          await tmp.rename(target.path);
        } catch (_) {
          await target.writeAsBytes(bytes, flush: true);
        }
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    });
    final savedRel = p.relative(
      p.join(root, '.my_ide', rel),
      from: p.join(root, '.my_ide'),
    );
    return 'asset:$savedRel';
  }

  /// R-PROBEIMG：压缩探针用——返回引用解析后的近似字符长度。
  /// 真实请求把 `asset:` 引用读盘转 base64 dataUrl（≈bytes×1.37+头），
  /// 探针只按 asset: 短引用计小头会系统性低估、压缩晚触发。
  /// 缺失/超限/链接返回 0（与 resolveChatImage 丢弃口径一致）；
  /// 非 asset 引用（已是 dataUrl）按原样字符长计。
  Future<int> chatImageResolvedLength(String ref) async {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return 0;
    if (!trimmed.startsWith('asset:')) return trimmed.length;
    final root = _projectRoot;
    if (root == null) return 0;
    final rel = trimmed.substring('asset:'.length).trim();
    if (rel.isEmpty) return 0;
    final normRel = p.normalize(rel).replaceAll('\\', '/');
    if (!normRel.startsWith('chat_assets/')) return 0;
    try {
      final base = p.normalize(p.join(root, '.my_ide'));
      final abs = p.normalize(p.join(base, rel));
      if (abs != base && !p.isWithin(base, abs)) return 0;
      if (FileSystemEntity.typeSync(abs, followLinks: false) ==
          FileSystemEntityType.link) {
        return 0;
      }
      final file = File(abs);
      if (!await file.exists()) return 0;
      final len = await file.length();
      if (len > 8 * 1024 * 1024) return 0;
      return (len * 1.37).round() + 64;
    } catch (_) {
      return 0;
    }
  }

  /// 删除会话时同步清理其图片资产目录，避免孤儿图片堆积。
  Future<void> _deleteChatAssets(String sessionId) async {
    final root = _projectRoot;
    if (root == null) return;
    // A2-6：删目录与 saveChatImageAsset 的写文件共用"会话资产目录"key
    // 串行——迟到写在删后排队执行，不再把孤儿图片重新写回复活。
    final assetKey = p.join(root, '.my_ide', 'chat_assets', sessionId);
    try {
      await _ChatCodec.enqueueKey(assetKey, () async {
        final dir = Directory(assetKey);
        if (await dir.exists()) await dir.delete(recursive: true);
      });
    } catch (_) {}
  }

  /// S2-7：分叉资产跟随复制——切点前消息 images 中的
  /// `asset:chat_assets/<源id>/...` 引用所指文件复制到新会话资产目录，
  /// 并改写消息引用。删源会话整目录删图时分支不断图。
  /// 复制失败尽力跳过（缺图不阻断分叉）。
  Future<void> _copyForkAssets({
    required String srcId,
    required String dstId,
    required List<ChatMessage> messages,
  }) async {
    final root = _projectRoot;
    if (root == null || srcId == dstId) return;
    final base = p.normalize(p.join(root, '.my_ide'));
    final prefix = 'chat_assets/$srcId/';
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.images.isEmpty) continue;
      var changed = false;
      final next = <String>[];
      for (final ref in m.images) {
        final trimmed = ref.trim();
        if (!trimmed.startsWith('asset:')) {
          next.add(ref);
          continue;
        }
        final rel = trimmed.substring('asset:'.length).trim();
        final normRel = p.normalize(rel).replaceAll('\\', '/');
        if (!normRel.startsWith(prefix)) {
          next.add(ref);
          continue;
        }
        try {
          final abs = p.normalize(p.join(base, normRel));
          // 与 resolveChatImage 同口径：base 内 + 拒 symlink。
          if (abs != base && !p.isWithin(base, abs)) {
            next.add(ref);
            continue;
          }
          if (FileSystemEntity.typeSync(abs, followLinks: false) ==
              FileSystemEntityType.link) {
            next.add(ref);
            continue;
          }
          final srcFile = File(abs);
          if (!await srcFile.exists()) {
            next.add(ref);
            continue;
          }
          final dstRel = p.join('chat_assets', dstId, p.basename(normRel));
          final dstFile = File(p.join(base, dstRel));
          await dstFile.parent.create(recursive: true);
          await srcFile.copy(dstFile.path);
          next.add('asset:$dstRel');
          changed = true;
        } catch (_) {
          next.add(ref);
        }
      }
      if (changed) messages[i] = m.copyWith(images: next);
    }
  }
}

// ---- 原 ChatStore 私有静态成员转同库顶层函数（part 内共享库导入）----

String _guessImageMime(String rel, List<int> bytes) {
final lower = rel.toLowerCase();
if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
if (lower.endsWith('.gif')) return 'image/gif';
if (lower.endsWith('.webp')) return 'image/webp';
if (lower.endsWith('.bmp')) return 'image/bmp';
if (bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47) {
  return 'image/png';
}
if (bytes.length >= 3 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[2] == 0xFF) {
  return 'image/jpeg';
}
return 'image/png';
}

bool _imageMagicMatches(String mime, List<int> bytes) {
bool head(List<int> sig) {
  if (bytes.length < sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (bytes[i] != sig[i]) return false;
  }
  return true;
}

switch (mime) {
  case 'image/png':
    return head([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  case 'image/jpeg':
    return bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF;
  case 'image/gif':
    return head([0x47, 0x49, 0x46, 0x38]);
  case 'image/webp':
    return bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
  case 'image/bmp':
    return head([0x42, 0x4D]);
  default:
    return false;
}
}

/// 解析内存 dataUrl 为字节 + mime（供 _save 落盘收敛用），非法返回 null。
({List<int> bytes, String mime})? _parseChatImageDataUrl(String url) {
try {
  final comma = url.indexOf(',');
  if (!url.startsWith('data:') || comma < 0) return null;
  final header = url.substring(5, comma);
  final mime = header.split(';').first.trim();
  if (mime.isEmpty || !mime.startsWith('image/')) return null;
  final body = url.substring(comma + 1);
  if (body.isEmpty || body.length > 12 * 1024 * 1024) return null;
  var normalized = body.replaceAll(RegExp(r'\s+'), '');
  final mod = normalized.length % 4;
  if (mod != 0) normalized += '=' * (4 - mod);
  final bytes = base64Decode(normalized);
  if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
  return (bytes: bytes, mime: mime);
} catch (_) {
  return null;
}
}
