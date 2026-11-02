import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/re_highlight.dart';

import 'code_completion_catalog.dart';

/// 基于 re_editor 默认补全，再叠加当前文件符号。
class IdeCompletionPromptsBuilder implements CodeAutocompletePromptsBuilder {
  IdeCompletionPromptsBuilder({
    required this.languageId,
    required Mode? languageMode,
    required CodeLineEditingController controller,
  })  : _controller = controller,
        _delegate = DefaultCodeAutocompletePromptsBuilder(
          language: languageMode,
          directPrompts: CodeCompletionCatalog.directPromptsFor(languageId),
          relatedPrompts: CodeCompletionCatalog.relatedPromptsFor(languageId),
        );

  final String languageId;
  final CodeLineEditingController _controller;
  final CodeAutocompletePromptsBuilder _delegate;

  /// R-COMPL-CACHE：符号提取按全文内容缓存——此前每次击键触发的
  /// build 对全文跑全量标识符正则，1MB 级文件 UI isolate 明显卡顿。
  /// 缓存键为全文内容（同文本直接复用），替换/删除旧值即失效。
  String? _symbolCacheText;
  List<CodePrompt>? _symbolCache;

  @override
  CodeAutocompleteEditingValue? build(
    BuildContext context,
    CodeLine codeLine,
    CodeLineSelection selection,
  ) {
    final base = _delegate.build(context, codeLine, selection);

    final text = _controller.text;
    // 内容等值比较（长度不等即短路）：同文本复用缓存，任何改动即重算。
    if (_symbolCacheText != text || _symbolCache == null) {
      _symbolCacheText = text;
      _symbolCache = CodeCompletionCatalog.symbolsFromSource(text);
    }
    final symbols = _symbolCache!;
    if (symbols.isEmpty) return base;

    // 解析当前输入前缀，把本地符号并入候选
    final before = codeLine.text.substring(0, selection.extentOffset);
    final match = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before);
    final input = match?.group(0) ?? '';
    if (input.isEmpty) {
      // 例如 `console.` 这种成员补全，交给默认逻辑
      return base;
    }

    final symbolHits = symbols.where((p) => p.match(input)).toList(growable: false);
    if (symbolHits.isEmpty) return base;

    // F9：lspPrompts 死分支删除——唯一构造点从未传参恒为空列表，
    // 合并逻辑里对空列表过滤是无效计算，直接去掉。
    if (base == null) {
      return CodeAutocompleteEditingValue(
        input: input,
        prompts: [...symbolHits],
        index: 0,
      );
    }

    final merged = <CodePrompt>[
      ...base.prompts,
      for (final prompt in symbolHits)
        if (!base.prompts.any((e) => e.word == prompt.word)) prompt,
    ];
    return base.copyWith(prompts: merged);
  }
}
