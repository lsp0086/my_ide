import 'package:flutter/material.dart';

import '../lsp/symbol_index.dart';
import '../lsp/symbol_rules.dart';

/// 基于 symbol_index 的大纲列表 widget（最小可用，只读展示）。
class OutlineView extends StatefulWidget {
  const OutlineView({
    super.key,
    required this.symbols,
    this.onJump,
    this.initialFilter = '',
    this.allowedKinds,
    this.activeLine,
    this.followCursor = false,
  });

  final List<IndexedSymbol> symbols;
  final void Function(IndexedSymbol symbol)? onJump;
  final String initialFilter;
  final Set<SymbolKind>? allowedKinds;
  final int? activeLine;
  final bool followCursor;

  @override
  State<OutlineView> createState() => _OutlineViewState();
}

class _OutlineViewState extends State<OutlineView> {
  late final TextEditingController _filterController;
  late final ScrollController _scrollController;
  String _filter = '';
  Set<SymbolKind> _kinds = {};

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter;
    _kinds = {...?widget.allowedKinds};
    _filterController = TextEditingController(text: _filter)
      ..addListener(() {
        if (!mounted) return;
        setState(() => _filter = _filterController.text);
      });
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.trim().toLowerCase();
    final filtered = widget.symbols.where((s) {
      final matchesText = query.isEmpty || s.name.toLowerCase().contains(query);
      final matchesKind = _kinds.isEmpty || _kinds.contains(s.kind);
      return matchesText && matchesKind;
    }).toList();
    return Column(
      children: [
        TextField(
          controller: _filterController,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: '过滤符号',
            isDense: true,
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: SymbolKind.values
                .map(
                  (kind) => FilterChip(
                    label: Text(kind.name),
                    selected: _kinds.contains(kind),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _kinds.add(kind);
                      } else {
                        _kinds.remove(kind);
                      }
                    }),
                  ),
                )
                .toList(),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('暂无符号'))
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final s = filtered[i];
                    final depth = _depthOf(s);
                    final active =
                        widget.followCursor &&
                        widget.activeLine != null &&
                        s.line <= widget.activeLine!;
                    return ListTile(
                      dense: true,
                      selected: active,
                      contentPadding: EdgeInsets.only(left: 8.0 + depth * 16),
                      leading: Icon(_iconFor(s.kind), size: 16),
                      title: Text(s.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${s.kind.name} · L${s.line + 1}'),
                      onTap: widget.onJump == null
                          ? null
                          : () => widget.onJump!(s),
                    );
                  },
                ),
        ),
      ],
    );
  }

  int _depthOf(IndexedSymbol symbol) {
    return symbol.name.contains('.') ? symbol.name.split('.').length - 1 : 0;
  }

  IconData _iconFor(SymbolKind kind) {
    switch (kind) {
      case SymbolKind.clazz:
        return Icons.class_outlined;
      case SymbolKind.function:
      case SymbolKind.method:
        return Icons.functions;
      case SymbolKind.variable:
      case SymbolKind.field:
        return Icons.data_object_outlined;
      case SymbolKind.enum_:
        return Icons.list_alt;
      default:
        return Icons.code;
    }
  }
}
