import 'package:flutter/material.dart';

class AppStrings {
  final String localeCode;
  const AppStrings(this.localeCode);

  bool get isZh => localeCode == 'zh';

  static AppStrings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_StringsScope>();
    return scope?.strings ?? const AppStrings('zh');
  }

  static const supported = ['zh', 'en'];

  String get settings => isZh ? '设置' : 'Settings';
  String get appearance => isZh ? '外观' : 'Appearance';
  String get appearanceDesc => isZh ? '选择 IDE 的整体色调风格' : 'Choose the overall IDE tone';
  String get themeStyle => isZh ? '界面风格' : 'Theme';
  String get light => isZh ? '亮色' : 'Light';
  String get dark => isZh ? '暗色' : 'Dark';
  String get language => isZh ? '语言' : 'Language';
  String get languageDesc => isZh ? '切换界面语言，默认中文' : 'UI language, default Chinese';
  String get codeHighlight => isZh ? '代码高亮' : 'Highlight';
  String get explorer => isZh ? '资源管理器' : 'Explorer';
  String get editor => isZh ? '编辑器' : 'Editor';
  String get aiAssistant => isZh ? 'AI 助手' : 'AI Assistant';
  String get newChat => isZh ? '新对话' : 'New chat';
  String get exportMd => isZh ? '导出为 MD' : 'Export MD';
  String get deleteChat => isZh ? '删除对话' : 'Delete chat';
  String get emptyChat => isZh ? '暂无对话，新建一个开始' : 'No chats yet';
  String get chatHint => isZh ? '描述你想做的改动…' : 'Describe your change…';
  String get providers => isZh ? '供应商' : 'Providers';
  String get providersDesc => isZh ? 'OpenAI 兼容 BaseURL + Token，拉取模型列表后配置' : 'OpenAI-compatible BaseURL + token';
  String get clearMemory => isZh ? '清除当前项目记忆' : 'Clear project memory';
  String get confirmDelete => isZh ? '确认删除该对话？记录清除但保留差量。' : 'Delete chat? History removed, checkpoints kept.';
}

class _StringsScope extends InheritedWidget {
  const _StringsScope({required this.strings, required super.child});
  final AppStrings strings;
  @override
  bool updateShouldNotify(_StringsScope old) => old.strings.localeCode != strings.localeCode;
}

class StringsScope extends StatelessWidget {
  const StringsScope({super.key, required this.strings, required this.child});
  final AppStrings strings;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return _StringsScope(strings: strings, child: child);
  }
}
