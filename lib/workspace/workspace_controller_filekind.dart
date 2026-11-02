part of 'workspace_controller.dart';

// ---- 原 WorkspaceController 私有静态成员转同库顶层（文本判定工具）----

bool _isValidUtf8(List<int> bytes) {
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    final int need;
    if (b <= 0x7F) {
      need = 0;
    } else if (b >= 0xC2 && b <= 0xDF) {
      need = 1;
    } else if (b >= 0xE0 && b <= 0xEF) {
      need = 2;
    } else if (b >= 0xF0 && b <= 0xF4) {
      need = 3;
    } else {
      return false;
    }

    if (i + need >= bytes.length) {
      // 采样末尾可能截断，视为可接受
      return true;
    }
    for (var j = 1; j <= need; j++) {
      final c = bytes[i + j];
      if (c < 0x80 || c > 0xBF) return false;
    }
    i += need + 1;
    if (i > 8192) {
      // 采样上限，防超大文件整文件扫描
      return false;
    }
  }
  return true;
}

const _textExtensions = <String>{
  '.dart',
  '.md',
  '.txt',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.html',
  '.css',
  '.js',
  '.ts',
  '.tsx',
  '.jsx',
  '.py',
  '.java',
  '.kt',
  '.swift',
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.gradle',
  '.properties',
  '.gitignore',
  '.toml',
  '.ini',
  '.sh',
  '.zsh',
  '.bash',
  '.cmake',
  '.plist',
  '.rb',
  '.go',
  '.rs',
  '.sql',
  '.log',
  '.lock',
  '.iml',
};

const _imageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
  '.ico',
  '.tif',
  '.tiff',
  '.heic',
};

const _ignoredNames = <String>{
  '.git',
  '.dart_tool',
  '.idea',
  '.vscode',
  '.trae',
  'build',
  'dist',
  'out',
  'coverage',
  '.next',
  'node_modules',
  'Pods',
  'DerivedData',
  '__pycache__',
  '.flutter-plugins-dependencies',
  '.packages',
};
