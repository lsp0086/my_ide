part of 'workspace_controller.dart';

enum FileKind { text, image, svg, unsupported, browser }

class WorkspaceFile {
  const WorkspaceFile({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.children = const [],
    this.childrenLoaded = true,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final List<WorkspaceFile> children;
  /// 懒加载标记：false 表示子目录尚未展开，占位空 children。
  final bool childrenLoaded;
}

class RevealTarget {
  const RevealTarget({required this.line, required this.character});

  final int line;
  final int character;
}

class OpenEditorTab {
  const OpenEditorTab({
    required this.path,
    required this.name,
    required this.kind,
    this.isDirty = false,
    this.url,
  });

  final String path;
  final String name;
  final FileKind kind;
  final bool isDirty;

  /// 页面标签页（FileKind.browser）的完整 URL；文件标签页为 null。
  final String? url;

  OpenEditorTab copyWith({bool? isDirty}) {
    return OpenEditorTab(
      path: path,
      name: name,
      kind: kind,
      isDirty: isDirty ?? this.isDirty,
      url: url,
    );
  }
}

/// 进程内项目锁：同进程多窗口（macOS 原生多窗口）共用一个 PID，
/// 文件 PID 锁区分不开自己人，所以进程内再按窗口持有者记一层。
/// key 为归一化项目路径，value 为持有该项目的控制器。
class _ProcessProjectLocks {
  static final Map<String, WorkspaceController> _owners = {};

  static WorkspaceController? ownerOf(String normalizedPath) =>
      _owners[normalizedPath];

  static void acquire(String normalizedPath, WorkspaceController owner) {
    _owners[normalizedPath] = owner;
  }

  static void release(String normalizedPath, WorkspaceController owner) {
    if (_owners[normalizedPath] == owner) {
      _owners.remove(normalizedPath);
    }
  }
}

class WorkspaceScope extends InheritedNotifier<WorkspaceController> {
  const WorkspaceScope({
    super.key,
    required WorkspaceController controller,
    required super.child,
  }) : super(notifier: controller);

  static WorkspaceController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
    assert(scope != null, 'WorkspaceScope not found in widget tree');
    return scope!.notifier!;
  }

  static WorkspaceController? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
    return scope?.notifier;
  }
}
