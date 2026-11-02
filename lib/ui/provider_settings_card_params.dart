part of 'provider_settings_card.dart';

class _ModelParamsTable extends StatefulWidget {
  const _ModelParamsTable({required this.model, required this.onChanged});

  final AiModelOption model;
  final VoidCallback onChanged;

  @override
  State<_ModelParamsTable> createState() => _ModelParamsTableState();
}

class _ModelParamsTableState extends State<_ModelParamsTable> {
  late List<_ParamRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = [
      for (final e in widget.model.customParams.entries)
        _ParamRow(keyCtrl: TextEditingController(text: e.key), valueCtrl: TextEditingController(text: e.value)),
      _ParamRow(keyCtrl: TextEditingController(), valueCtrl: TextEditingController()),
    ];
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.keyCtrl.dispose();
      r.valueCtrl.dispose();
    }
    super.dispose();
  }

  void _commit() {
    final out = <String, String>{};
    for (final r in _rows) {
      final k = r.keyCtrl.text.trim();
      final v = r.valueCtrl.text.trim();
      // key 和值均不为空才保存。
      if (k.isEmpty || v.isEmpty) continue;
      out[k] = v;
    }
    widget.model.customParams = out;
    widget.onChanged();
    // 保证末尾恒有一行空行可继续输入。
    final last = _rows.last;
    if (last.keyCtrl.text.trim().isNotEmpty ||
        last.valueCtrl.text.trim().isNotEmpty) {
      setState(() {
        _rows.add(_ParamRow(
            keyCtrl: TextEditingController(),
            valueCtrl: TextEditingController()));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('自定义参数', style: TextStyle(color: colors.textMuted, fontSize: 11)),
        const SizedBox(height: 6),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(1),
            1: FlexColumnWidth(1),
            2: IntrinsicColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            for (var i = 0; i < _rows.length; i++)
              TableRow(
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                        right: 6, bottom: i == _rows.length - 1 ? 0 : 6),
                    child: TextField(
                      controller: _rows[i].keyCtrl,
                      style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo'),
                      decoration: InputDecoration(
                        hintText: i == 0 ? 'key，如 temperature' : 'key',
                        isDense: true,
                        filled: true,
                        fillColor: colors.inputFill,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onChanged: (_) => _commit(),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                        right: 6, bottom: i == _rows.length - 1 ? 0 : 6),
                    child: TextField(
                      controller: _rows[i].valueCtrl,
                      style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo'),
                      decoration: InputDecoration(
                        hintText: i == 0 ? 'value，如 0.7' : 'value',
                        isDense: true,
                        filled: true,
                        fillColor: colors.inputFill,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onChanged: (_) => _commit(),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                        bottom: i == _rows.length - 1 ? 0 : 6),
                    child: IconButton(
                      tooltip: '删除该行',
                      visualDensity: VisualDensity.compact,
                      onPressed: _rows.length == 1 &&
                              _rows.first.keyCtrl.text.isEmpty &&
                              _rows.first.valueCtrl.text.isEmpty
                          ? null
                          : () {
                              setState(() {
                                final removed = _rows.removeAt(i);
                                removed.keyCtrl.dispose();
                                removed.valueCtrl.dispose();
                                if (_rows.isEmpty) {
                                  _rows.add(_ParamRow(
                                      keyCtrl: TextEditingController(),
                                      valueCtrl: TextEditingController()));
                                }
                              });
                              _commit();
                            },
                      icon: Icon(Icons.close_rounded,
                          size: 14, color: colors.textMuted),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text('每行一对 key/value，均不为空才保存，随请求透传。',
            style: TextStyle(color: colors.textMuted, fontSize: 10.5)),
      ],
    );
  }
}

class _ParamRow {
  _ParamRow({required this.keyCtrl, required this.valueCtrl});
  final TextEditingController keyCtrl;
  final TextEditingController valueCtrl;
}
