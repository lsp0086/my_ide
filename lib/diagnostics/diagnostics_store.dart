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
    return List.unmodifiable(_byFile[path] ?? const []);
  }

  List<IdeDiagnostic> get allDiagnostics {
    final out = <IdeDiagnostic>[];
    for (final list in _byFile.values) {
      out.addAll(list);
    }
    out.sort(_compare);
    return List.unmodifiable(out);
  }

  int get errorCount => _countSeverity(DiagnosticSeverity.error);
  int get warningCount => _countSeverity(DiagnosticSeverity.warning);
  int get infoCount => _countSeverity(DiagnosticSeverity.info);
  int get totalCount =>
      _byFile.values.fold<int>(0, (sum, list) => sum + list.length);

  int errorCountOf(String path) =>
      _countSeverityOf(path, DiagnosticSeverity.error);

  int warningCountOf(String path) =>
      _countSeverityOf(path, DiagnosticSeverity.warning);

  Map<int, DiagnosticSeverity> severitiesByLine(String path) {
    final map = <int, DiagnosticSeverity>{};
    for (final d in _byFile[path] ?? const <IdeDiagnostic>[]) {
      final existing = map[d.startLine];
      if (existing == null || _rank(d.severity) < _rank(existing)) {
        map[d.startLine] = d.severity;
      }
    }
    return map;
  }

  /// 整文件替换某一来源；其它来源保留。
  void setForFileSource({
    required String path,
    required String source,
    required List<IdeDiagnostic> diagnostics,
    int? contentVersion,
  }) {
    final version = contentVersion ?? (_contentVersion[path] ?? 0);
    final others = (_byFile[path] ?? const <IdeDiagnostic>[])
        .where((d) => d.source != source)
        .toList();
    final incoming = diagnostics
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
    final next = diagnostics
        .map((d) => d.contentVersion == version
            ? d
            : d.copyWith(contentVersion: version))
        .where((d) => d.contentVersion == version)
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
    notifyListeners();
  }

  int _countSeverity(DiagnosticSeverity severity) {
    var n = 0;
    for (final list in _byFile.values) {
      for (final d in list) {
        if (d.severity == severity) n++;
      }
    }
    return n;
  }

  int _countSeverityOf(String path, DiagnosticSeverity severity) {
    var n = 0;
    for (final d in _byFile[path] ?? const <IdeDiagnostic>[]) {
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
