import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum ShortcutAction {
  saveFile,
}

class ShortcutBinding {
  const ShortcutBinding({
    required this.key,
    required this.modifiers,
  });

  final LogicalKeyboardKey key;
  final Set<LogicalKeyboardKey> modifiers;

  SingleActivator toActivator() {
    return SingleActivator(
      key,
      control: modifiers.contains(LogicalKeyboardKey.control),
      meta: modifiers.contains(LogicalKeyboardKey.meta),
      shift: modifiers.contains(LogicalKeyboardKey.shift),
      alt: modifiers.contains(LogicalKeyboardKey.alt),
    );
  }

  String get displayLabel {
    final parts = <String>[];
    final isMac = !kIsWeb && Platform.isMacOS;

    if (modifiers.contains(LogicalKeyboardKey.control)) {
      parts.add(isMac ? '⌃' : 'Ctrl');
    }
    if (modifiers.contains(LogicalKeyboardKey.alt)) {
      parts.add(isMac ? '⌥' : 'Alt');
    }
    if (modifiers.contains(LogicalKeyboardKey.shift)) {
      parts.add(isMac ? '⇧' : 'Shift');
    }
    if (modifiers.contains(LogicalKeyboardKey.meta)) {
      parts.add(isMac ? '⌘' : 'Win');
    }

    parts.add(_keyLabel(key));
    return isMac ? parts.join('') : parts.join('+');
  }

  static String _keyLabel(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.isNotEmpty) return label.toUpperCase();
    return key.debugName ?? 'Key';
  }

  @override
  bool operator ==(Object other) {
    return other is ShortcutBinding &&
        other.key == key &&
        setEquals(other.modifiers, modifiers);
  }

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(modifiers));
}

class ShortcutController extends ChangeNotifier {
  ShortcutController() {
    _bindings = Map<ShortcutAction, ShortcutBinding>.from(_defaults);
  }

  late Map<ShortcutAction, ShortcutBinding> _bindings;
  ShortcutAction? _capturingAction;

  ShortcutAction? get capturingAction => _capturingAction;

  static ShortcutBinding get _defaultSave {
    final isMac = !kIsWeb && Platform.isMacOS;
    return ShortcutBinding(
      key: LogicalKeyboardKey.keyS,
      modifiers: {
        if (isMac) LogicalKeyboardKey.meta else LogicalKeyboardKey.control,
      },
    );
  }

  static Map<ShortcutAction, ShortcutBinding> get _defaults => {
        ShortcutAction.saveFile: _defaultSave,
      };

  ShortcutBinding bindingOf(ShortcutAction action) {
    return _bindings[action] ?? _defaults[action]!;
  }

  SingleActivator activatorOf(ShortcutAction action) {
    return bindingOf(action).toActivator();
  }

  void beginCapture(ShortcutAction action) {
    if (_capturingAction == action) return;
    _capturingAction = action;
    notifyListeners();
  }

  void cancelCapture() {
    if (_capturingAction == null) return;
    _capturingAction = null;
    notifyListeners();
  }

  bool captureKeyEvent(KeyEvent event) {
    final action = _capturingAction;
    if (action == null || event is! KeyDownEvent) return false;

    final key = event.logicalKey;
    if (_isModifier(key)) return true;

    final modifiers = <LogicalKeyboardKey>{};
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    if (pressed.contains(LogicalKeyboardKey.control) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight)) {
      modifiers.add(LogicalKeyboardKey.control);
    }
    if (pressed.contains(LogicalKeyboardKey.meta) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight)) {
      modifiers.add(LogicalKeyboardKey.meta);
    }
    if (pressed.contains(LogicalKeyboardKey.alt) ||
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight)) {
      modifiers.add(LogicalKeyboardKey.alt);
    }
    if (pressed.contains(LogicalKeyboardKey.shift) ||
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight)) {
      modifiers.add(LogicalKeyboardKey.shift);
    }

    if (modifiers.isEmpty) {
      // 没有修饰键时放行，不拦截普通键盘输入（如打字）
      return false;
    }

    _bindings[action] = ShortcutBinding(key: key, modifiers: modifiers);
    _capturingAction = null;
    notifyListeners();
    return true;
  }

  void resetToDefault(ShortcutAction action) {
    _bindings[action] = _defaults[action]!;
    if (_capturingAction == action) {
      _capturingAction = null;
    }
    notifyListeners();
  }

  static bool _isModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight;
  }
}

class ShortcutScope extends InheritedNotifier<ShortcutController> {
  const ShortcutScope({
    super.key,
    required ShortcutController controller,
    required super.child,
  }) : super(notifier: controller);

  static ShortcutController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ShortcutScope>();
    assert(scope != null, 'ShortcutScope not found in widget tree');
    return scope!.notifier!;
  }
}
