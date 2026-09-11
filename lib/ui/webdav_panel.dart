import 'package:flutter/material.dart';

import '../settings/settings_store.dart';
import '../settings/webdav_backup.dart';
import '../theme/app_colors.dart';

class WebDavPanel extends StatefulWidget {
  const WebDavPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  State<WebDavPanel> createState() => _WebDavPanelState();
}

class _WebDavPanelState extends State<WebDavPanel> {
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _remotePath;
  bool _passwordVisible = false;
  bool _busy = false;

  static const _defaultRemotePath = '/my_ide/settings-backup.json';

  @override
  void initState() {
    super.initState();
    final store = SettingsStore.instance;
    _url = TextEditingController(text: store.getString('webdav.url') ?? '');
    _username =
        TextEditingController(text: store.getString('webdav.username') ?? '');
    _password =
        TextEditingController(text: store.getString('webdav.password') ?? '');
    final path = store.getString('webdav.remotePath')?.trim();
    _remotePath = TextEditingController(
      text: (path == null || path.isEmpty) ? _defaultRemotePath : path,
    );
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _remotePath.dispose();
    super.dispose();
  }

  InputDecoration _fieldDeco(
    IdeColors colors, {
    required String label,
    String? hint,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: colors.inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: TextStyle(color: colors.textMuted, fontSize: 12),
      hintStyle:
          TextStyle(color: colors.textMuted.withValues(alpha: 0.7), fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.55)),
      ),
      suffixIcon: suffix,
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  WebDavConfig _configFromFields() {
    final path = _remotePath.text.trim();
    return WebDavConfig(
      url: _url.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      remotePath: path.isEmpty ? _defaultRemotePath : path,
    );
  }

  Future<void> _saveConfig() async {
    final store = SettingsStore.instance;
    final path = _remotePath.text.trim();
    await store.setString('webdav.url', _url.text.trim());
    await store.setString('webdav.username', _username.text.trim());
    await store.setString('webdav.password', _password.text);
    await store.setString(
      'webdav.remotePath',
      path.isEmpty ? _defaultRemotePath : path,
    );
    _snack('WebDAV 配置已保存');
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupUpload() async {
    await _runBusy(() async {
      final cfg = _configFromFields();
      if (cfg.url.isEmpty) {
        _snack('请先填写 WebDAV URL');
        return;
      }
      try {
        await _saveConfig();
        await WebDavBackup.upload(SettingsStore.instance, cfg);
        _snack('备份上传成功');
      } catch (e) {
        _snack('备份上传失败：$e');
      }
    });
  }

  Future<void> _restoreFromRemote() async {
    await _runBusy(() async {
      final cfg = _configFromFields();
      if (cfg.url.isEmpty) {
        _snack('请先填写 WebDAV URL');
        return;
      }
      try {
        await _saveConfig();
        final payload = await WebDavBackup.download(cfg);
        await WebDavBackup.restore(SettingsStore.instance, payload);
        _snack('已从远端恢复设置');
      } catch (e) {
        _snack('恢复失败：$e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final fieldStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 12.5,
      fontFamily: 'Menlo',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: Row(
            children: [
              Text(
                'WebDAV 备份',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              if (_busy) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                ),
              ],
              const Spacer(),
              if (widget.onClose != null)
                IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close_rounded,
                      size: 16, color: colors.textMuted),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            children: [
              Container(
                decoration: BoxDecoration(
                  color: colors.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: colors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                      child: Row(
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: colors.accentSoft,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.cloud_sync_outlined,
                                size: 15, color: colors.accent),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '登录与备份',
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 20, color: colors.divider),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _url,
                            style: fieldStyle,
                            decoration: _fieldDeco(
                              colors,
                              label: 'WebDAV URL',
                              hint:
                                  'https://dav.example.com/remote.php/dav/files/user',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _username,
                            style: fieldStyle,
                            decoration: _fieldDeco(colors, label: '用户名'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _password,
                            obscureText: !_passwordVisible,
                            style: fieldStyle,
                            decoration: _fieldDeco(
                              colors,
                              label: '密码',
                              suffix: IconButton(
                                tooltip:
                                    _passwordVisible ? '隐藏密码' : '显示密码',
                                onPressed: () => setState(
                                    () => _passwordVisible = !_passwordVisible),
                                icon: Icon(
                                  _passwordVisible
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 18,
                                  color: colors.textMuted,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _remotePath,
                            style: fieldStyle,
                            decoration: _fieldDeco(
                              colors,
                              label: '远端路径',
                              hint: _defaultRemotePath,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _ActionButton(
                                icon: Icons.save_outlined,
                                label: '保存配置',
                                filled: true,
                                onTap: _busy ? null : _saveConfig,
                              ),
                              _ActionButton(
                                icon: Icons.cloud_upload_outlined,
                                label: '备份上传',
                                onTap: _busy ? null : _backupUpload,
                              ),
                              _ActionButton(
                                icon: Icons.cloud_download_outlined,
                                label: '从远端恢复',
                                onTap: _busy ? null : _restoreFromRemote,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final enabled = onTap != null;
    return Material(
      color: filled
          ? (enabled ? colors.accentSoft : colors.panelHover)
          : colors.panelHover,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: filled
                  ? colors.accent.withValues(alpha: enabled ? 0.35 : 0.12)
                  : colors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: filled
                    ? (enabled ? colors.accent : colors.textMuted)
                    : colors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: filled
                      ? (enabled ? colors.accent : colors.textMuted)
                      : colors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
