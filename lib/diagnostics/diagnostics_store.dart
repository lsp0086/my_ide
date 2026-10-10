import 'package:flutter/material.dart';

import 'ide_diagnostic.dart';

/// 诊断仓库：按文件整表替换，对齐 LSP publishDiagnostics 语义。
class DiagnosticsStore extends ChangeNotifier {
  final Map<String, List<IdeDiagnostic>> _byFile = {};
  final Map<String, int> _contentVersion = {};
  bool _showProblems = false;

  bool get showProblems => _showProblems;

  void setShowProblems(bool value) {
    if (_showProblems == value) return;
    _showProblems = value;
    notifyListeners();
  }

  void toggleProblems() => setShowProblems(!_showProblems);

  int contentVersionOf(String path) => _contentVersion[path] ?? 0;

  /// 文档内容变更时递增版本；过期诊断不立即清空，保留展示直到新诊断回包覆盖。
  /// 避免每次击键清空全文件诊断再闪回：LSP 慢回包期间仍显示上一版结果。
  int bumpContentVersion(String path) {
    final next = (_contentVersion[path] ?? 0) + 1;
    _contentVersion[path] = next;
    return next;
  }

  List<IdeDiagnostic> diagnosticsOf(String path) {
    return List.unmodifiable(
        _dedupKeepFirst(_byFile[path] ?? const <IdeDiagnostic>[]));
  }

  List<IdeDiagnostic> get allDiagnostics {
    final out = <IdeDiagnostic>[];
    for (final list in _byFile.values) {
      out.addAll(list);
    }
    final deduped = _dedupKeepFirst(out)..sort(_compare);
    return List.unmodifiable(deduped);
  }

  int get errorCount => _countSeverity(DiagnosticSeverity.error);
  int get warningCount => _countSeverity(DiagnosticSeverity.warning);
  int get infoCount => _countSeverity(DiagnosticSeverity.info);
  int get totalCount =>
      _byFile.values.fold<int>(0, (sum, list) => sum + _dedupKeepFirst(list).length);

  int errorCountOf(String path) =>
      _countSeverityOf(path, DiagnosticSeverity.error);

  int warningCountOf(String path) =>
      _countSeverityOf(path, DiagnosticSeverity.warning);

  Map<int, DiagnosticSeverity> severitiesByLine(String path) {
    final map = <int, DiagnosticSeverity>{};
    for (final d
        in _dedupKeepFirst(_byFile[path] ?? const <IdeDiagnostic>[])) {
      final existing = map[d.startLine];
      if (existing == null || _rank(d.severity) < _rank(existing)) {
        map[d.startLine] = d.severity;
      }
    }
    return map;
  }

  /// 整文件替换某一来源；其它来源保留。
  /// 迟到包防护：incoming 版本低于已存同源版本时直接丢弃，
  /// 否则慢回包会覆盖用户新编辑后的诊断（此前按到达时版本写入必覆盖）。
  void setForFileSource({
    required String path,
    required String source,
    required List<IdeDiagnostic> diagnostics,
    int? contentVersion,
  }) {
    final version = contentVersion ?? (_contentVersion[path] ?? 0);
    final existing = _byFile[path] ?? const <IdeDiagnostic>[];
    var newestSameSource = -1;
    for (final d in existing) {
      if (d.source == source && d.contentVersion > newestSameSource) {
        newestSameSource = d.contentVersion;
      }
    }
    if (newestSameSource > version) return;
    final others =
        existing.where((d) => d.source != source).toList();
    // R4-A5 单源上限2000：恶意 LSP 十万条此前常驻内存。
    // 轮次1：先按 _compare 排序再取尾部——此前截断在排序前，"保留最新"
    // 依赖调用方传入顺序，不保证最新。排序用副本（调用方可能传 unmodifiable）。
    var capped = List.of(diagnostics)..sort(_compare);
    if (capped.length > 2000) {
      capped = capped.sublist(capped.length - 2000);
    }
    final incoming = capped
        .map((d) => IdeDiagnostic(
              filePath: d.filePath,
              startLine: d.startLine,
              startChar: d.startChar,
              endLine: d.endLine,
              endChar: d.endChar,
              severity: d.severity,
              message: d.message,
              source: source,
              code: d.code,
              contentVersion: version,
            ))
        .toList();
    final merged = [...others, ...incoming]..sort(_compare);
    if (merged.isEmpty) {
      _byFile.remove(path);
    } else {
      _byFile[path] = merged;
    }
    notifyListeners();
  }

  /// 整文件替换全部来源。
  void setForFile(String path, List<IdeDiagnostic> diagnostics) {
    final version = _contentVersion[path] ?? 0;
    // 轮次1：copyWith 后 contentVersion 恒等于 version，冗余 where 过滤
    // 为死代码，删除。
    final next = diagnostics
        .map((d) => d.contentVersion == version
            ? d
            : d.copyWith(contentVersion: version))
        .toList()
      ..sort(_compare);
    if (next.isEmpty) {
      _byFile.remove(path);
    } else {
      _byFile[path] = next;
    }
    notifyListeners();
  }

  void clearFile(String path) {
    if (_byFile.remove(path) == null) return;
    // R15R9：清文件即删版本键——此前版本残留，重建同路径后旧诊断
    // 按 bump 后的新版本误收（迟到包防护 newestSameSource>version 失效）。
    _contentVersion.remove(path);
    notifyListeners();
  }

  void clearSource(String source) {
    var changed = false;
    final keys = _byFile.keys.toList();
    for (final path in keys) {
      final list = _byFile[path]!;
      final kept =
          list.where((d) => d.source != source).toList(growable: false);
      if (kept.length != list.length) {
        changed = true;
        if (kept.isEmpty) {
          _byFile.remove(path);
        } else {
          _byFile[path] = kept;
        }
      }
    }
    if (changed) notifyListeners();
  }

  void clearAll() {
    if (_byFile.isEmpty) return;
    _byFile.clear();
    // R15R9：同 clearFile，版本键同步清空。
    _contentVersion.clear();
    notifyListeners();
  }

  /// 展示层去重：各 source（lsp:xxx / local:tsc / …）对同一位置同一问题
  /// （line/col/code/message）各存一份，读取时保留首个 source 的条目，
  /// 问题面板不再重复展示。存储不动：条目仍归属各自 source，clearSource
  /// 清空某来源时仅移除属于它的条目，另一来源的条目照常显示。
  static List<IdeDiagnostic> _dedupKeepFirst(Iterable<IdeDiagnostic> input) {
    final seen = <String>{};
    final out = <IdeDiagnostic>[];
    for (final d in input) {
      final key = '${d.filePath}\u0000${d.startLine}\u0000${d.startChar}'
          '\u0000${d.code ?? ''}\u0000${d.message}';
      if (seen.add(key)) out.add(d);
    }
    return out;
  }

  int _countSeverity(DiagnosticSeverity severity) {
    var n = 0;
    for (final list in _byFile.values) {
      for (final d in _dedupKeepFirst(list)) {
        if (d.severity == severity) n++;
      }
    }
    return n;
  }

  int _countSeverityOf(String path, DiagnosticSeverity severity) {
    var n = 0;
    for (final d in _dedupKeepFirst(_byFile[path] ?? const <IdeDiagnostic>[])) {
      if (d.severity == severity) n++;
    }
    return n;
  }

  static int _rank(DiagnosticSeverity s) {
    switch (s) {
      case DiagnosticSeverity.error:
        return 0;
      case DiagnosticSeverity.warning:
        return 1;
      case DiagnosticSeverity.info:
        return 2;
      case DiagnosticSeverity.hint:
        return 3;
    }
  }

  static int _compare(IdeDiagnostic a, IdeDiagnostic b) {
    final bySeverity = _rank(a.severity).compareTo(_rank(b.severity));
    if (bySeverity != 0) return bySeverity;
    final byPath = a.filePath.compareTo(b.filePath);
    if (byPath != 0) return byPath;
    final byLine = a.startLine.compareTo(b.startLine);
    if (byLine != 0) return byLine;
    return a.startChar.compareTo(b.startChar);
  }
}

class DiagnosticsScope extends InheritedNotifier<DiagnosticsStore> {
  const DiagnosticsScope({
    super.key,
    required DiagnosticsStore store,
    required super.child,
  }) : super(notifier: store);

  static DiagnosticsStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DiagnosticsScope>();
    assert(scope != null, 'DiagnosticsScope not found');
    return scope!.notifier!;
  }

  static DiagnosticsStore? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<DiagnosticsScope>()
        ?.notifier;
  }
}
