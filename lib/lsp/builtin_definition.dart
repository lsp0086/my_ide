import 'lsp_client.dart';
import 'symbol_index.dart';
import 'symbol_rules.dart';

/// 无 LSP 时的内置定义跳转：符号索引 → 同文件规则 → 兜底。
class BuiltinDefinition {
  BuiltinDefinition._();

  static final _ident = RegExp(r'[A-Za-z_\$][A-Za-z0-9_\$]*');

  /// 从文本中取光标处标识符。
  static String? identifierAt(String text, int offset) {
    if (text.isEmpty) return null;
    final clamped = offset.clamp(0, text.length);
    Match? hit;
    for (final m in _ident.allMatches(text)) {
      if (clamped >= m.start && clamped <= m.end) {
        hit = m;
        break;
      }
    }
    if (hit == null) {
      final left = (clamped - 1).clamp(0, text.length);
      for (final m in _ident.allMatches(text)) {
        if (left >= m.start && left < m.end) {
          hit = m;
          break;
        }
      }
    }
    return hit?.group(0);
  }

  static Future<LspLocation?> find({
    required String rootPath,
    required String currentPath,
    required String currentSource,
    required String symbol,
    required int currentLine,
  }) async {
    // 1) 工作区符号索引（ctags 风格多语言规则建表）
    final indexed = SymbolIndex.instance.lookup(
      name: symbol,
      currentPath: currentPath,
      currentLine: currentLine,
    );
    if (indexed != null) return indexed;

    // 2) 当前文件即时提取（未入索引或刚改未保存）
    final lang = rulesForExtension(_extOf(currentPath));
    if (lang != null) {
      final local = extractSymbols(
        filePath: currentPath,
        source: currentSource,
        rules: lang,
      );
      for (final s in local) {
        if (s.name != symbol) continue;
        if (s.line == currentLine) continue;
        return s.toLocation();
      }
    }

    // 3) 索引可能还在建：触发一次后台重建（不阻塞太久）
    if (SymbolIndex.instance.rootPath == rootPath &&
        SymbolIndex.instance.symbolCount == 0 &&
        !SymbolIndex.instance.indexing) {
      // fire-and-forget
      SymbolIndex.instance.rebuild();
    }
    return null;
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return '';
    return path.substring(i).toLowerCase();
  }
}
