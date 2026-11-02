import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/agent_client.dart';
import '../ai/provider_config.dart';
import '../settings/settings_store.dart';
import '../theme/app_colors.dart';

part 'provider_settings_card_editor.dart';
part 'provider_settings_card_models.dart';
part 'provider_settings_card_params.dart';
part 'provider_settings_card_widgets.dart';

class ProviderSettingsCard extends StatefulWidget {
  const ProviderSettingsCard({super.key});

  @override
  State<ProviderSettingsCard> createState() => _ProviderSettingsCardState();
}

class _ProviderSettingsCardState extends State<ProviderSettingsCard> {
  List<AiProviderConfig> _providers = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    // R17-02（A4-2）：initState 是同步上下文不能 await——加载改异步方法，
    // 走 providersResolved 异步解密（v5 密文同步 providersRaw 必降级空串，
    // 进设置页 Token 框恒空、误判用户没填）。
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    final raw = await SettingsStore.instance.providersResolved();
    // 异步间隙用户可能已离开设置页。
    if (!mounted) return;
    setState(() {
      _providers = raw.map((e) => AiProviderConfig.fromJson(e)).toList();
    });
  }

  Future<void> _persist() async {
    // R-PROVIDERS-CORRUPT-GUARD：saveProviders 可能拒绝覆写（盘上配置
    // 损坏/新表丢失既有 id）——此处 catch 并显示，否则既成未处理异步
    // 错误，用户也看不到"保存为什么没生效"。
    try {
      // R17-02（A4-2）：_persist 前异步读回真值——v5 密文在 providersRaw
      // 同步路径降级空串，内存条目 token='' 直接 toJson 落盘即把盘上密文
      // 覆写成空（坏 key 与可解条目都中招）。修复口径同 updateModelOption：
      // 可解条目回填解密真值；坏 key 条目标 _secretUnreadable 让落盘沿用
      // 盘上原密文（_saveProvidersLocked 的 R5-P1 回填分支）。
      final resolved = await SettingsStore.instance.providersResolved();
      final resolvedById = <String, Map<String, dynamic>>{
        for (final m in resolved) '${m['id'] ?? ''}': m,
      };
      final payload = _providers.map((p) {
        final j = p.toJson();
        final real = resolvedById[p.id];
        final realToken = real == null ? '' : '${real['token'] ?? ''}';
        if ('${j['token'] ?? ''}'.isEmpty && realToken.isNotEmpty) {
          j['token'] = realToken;
        }
        if (real?['_secretUnreadable'] == true) {
          j['_secretUnreadable'] = true;
        }
        return j;
      }).toList();
      await SettingsStore.instance.saveProviders(payload);
      if (mounted && _error != null) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      children: [
        for (var i = 0; i < _providers.length; i++)
          _ProviderEditor(
            key: ValueKey(_providers[i].id),
            provider: _providers[i],
            onChanged: (_) => _persist(),
            onDelete: () async {
              _providers.removeAt(i);
              await _persist();
              if (mounted) setState(() {});
            },
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: _SoftActionButton(
            icon: Icons.add_rounded,
            label: '添加供应商',
            onTap: () async {
              _providers.add(AiProviderConfig(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: 'OpenAI 兼容',
                baseUrl: 'https://api.openai.com',
                fullUrl: false,
              ));
              await _persist();
              if (mounted) setState(() {});
            },
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: colors.accent, fontSize: 12)),
        ],
      ],
    );
  }
}

