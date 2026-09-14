/// 诊断严重级别（对齐 LSP DiagnosticSeverity 语义）。
enum DiagnosticSeverity {
  error,
  warning,
  info,
  hint,
}

/// 统一诊断模型。行号/列号内部一律 0-based。
class IdeDiagnostic {
  const IdeDiagnostic({
    required this.filePath,
    required this.startLine,
    required this.startChar,
    required this.endLine,
    required this.endChar,
    required this.severity,
    required this.message,
    required this.source,
    this.code,
    this.contentVersion = 0,
  });

  final String filePath;
  final int startLine;
  final int startChar;
  final int endLine;
  final int endChar;
  final DiagnosticSeverity severity;
  final String message;
  final String source;
  final String? code;

  /// 产生该诊断时的文档版本；内容变更后可用于失效。
  final int contentVersion;

  /// UI 展示用 1-based 行号。
  int get displayLine => startLine + 1;

  /// UI 展示用 1-based 列号。
  int get displayColumn => startChar + 1;

  IdeDiagnostic copyWith({
    int? startLine,
    int? startChar,
    int? endLine,
    int? endChar,
    int? contentVersion,
  }) {
    return IdeDiagnostic(
      filePath: filePath,
      startLine: startLine ?? this.startLine,
      startChar: startChar ?? this.startChar,
      endLine: endLine ?? this.endLine,
      endChar: endChar ?? this.endChar,
      severity: severity,
      message: message,
      source: source,
      code: code,
      contentVersion: contentVersion ?? this.contentVersion,
    );
  }
}
