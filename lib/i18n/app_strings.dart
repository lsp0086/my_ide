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
  String get deleteChatAndMergeVersions =>
      isZh ? '删除对话&合并版本' : 'Delete chat & merge versions';
  String get emptyChat => isZh ? '暂无对话，新建一个开始' : 'No chats yet';
  String get chatHint => isZh ? '描述你想做的改动…' : 'Describe your change…';
  String get providers => isZh ? '供应商' : 'Providers';
  String get providersDesc => isZh ? 'OpenAI 兼容 BaseURL + Token，拉取模型列表后配置' : 'OpenAI-compatible BaseURL + token';
  String get cleanProject => isZh ? '清理项目' : 'Clean project';
  String get cleanProjectDesc => isZh
      ? '清理当前项目的对话与记忆数据，不会删除工作区源码'
      : 'Clear chats and memory for this project without deleting source files';
  String get clearChats => isZh ? '清理对话' : 'Clear chats';
  String get clearChatsDesc =>
      isZh ? '仅删除所有对话，保留版本记录' : 'Delete all chats, keep version history';
  String get clearProjectMemory => isZh ? '清空项目记忆' : 'Clear project memory';
  String get clearProjectMemoryDesc => isZh
      ? '删除所有对话和版本记录'
      : 'Delete all chats and version history';
  String get confirmDeleteChat => isZh
      ? '仅删除该对话记录，保留相关版本。'
      : 'Delete this chat only. Version history is kept.';
  String get confirmDeleteChatAndMerge => isZh
      ? '删除该对话，并合并/清理其关联版本节点。'
      : 'Delete this chat and merge/drop its linked versions.';
  String get confirmClearChats => isZh
      ? '将删除当前项目的全部对话，版本记录会保留。'
      : 'Delete all chats in this project. Version history is kept.';
  String get confirmClearProjectMemory => isZh
      ? '将删除全部对话、版本记录与项目记忆，此操作不可撤销。'
      : 'Delete all chats, versions, and project memory. This cannot be undone.';

  @Deprecated('Use cleanProject / clearProjectMemory')
  String get clearMemory => clearProjectMemory;
  @Deprecated('Use confirmDeleteChat')
  String get confirmDelete => confirmDeleteChat;
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
