import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:meta/meta.dart';

import '../settings/settings_store.dart';
import 'app_logger.dart';
import '../lsp/bundled_language_servers.dart';
import 'ide_diagnostic.dart';

/// 用已下载的 TypeScript `tsc` 做本地 JS/TS 语义检查（不写项目 jsconfig）。
///
/// 对无配置 `.js`：`tsc --allowJs --checkJs --noEmit`
/// 这样 `consle` 一类错误不依赖 LSP configuration 通道。
/// 全局队列：同一时刻最多 2 个 tsc 进程，超请求排队复用项目 tsconfig，
/// 不再每次都起 `tmpDir+node tsc` 多进程轰炸。
class LocalTscChecker {
  static const source = 'local:tsc';
  static int _inflight = 0;
  // R-DEADCODE-INFLIGHT：公共 getter 已删——全库零调用（_inflight 字段
  // 本身仍由排队逻辑内部使用，勿删字段）。

  /// E2：排队等待者计数——忙等队列上限用，防洪水调用无界滞留。
  static int _waiters = 0;

  /// 测试专用：覆盖 tsc/node 解析，绕过 Application Support / path_provider。
  static ({String tsc, String node})? debugResolverOverride;

  static bool supports(String languageId, String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (const {'.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'}.contains(ext)) {
      return true;
    }
    return languageId == 'javascript' ||
        languageId == 'typescript' ||
        languageId == 'javascriptreact' ||
        languageId == 'typescriptreact';
  }

  static Future<List<IdeDiagnostic>> analyze({
    required String filePath,
    required String text,
    required String languageId,
    String? projectRoot,
    int contentVersion = 0,
  }) async {
    if (!supports(languageId, filePath)) return const [];
    final isJs = const {'.js', '.jsx', '.mjs', '.cjs'}
        .contains(p.extension(filePath).toLowerCase());
    // D6-L18：SettingsStore 未初始化时不得抛——此前 instance 的 `!`
    // 在启动早期（checkJs 读取先于 SettingsStore.init）直接 StateError
    // 崩分析调用点。未初始化按默认（jsImplicitCheckJs 默认 true）继续。
    final store = SettingsStore.maybeInstance;
    final implicitCheckJs = store?.jsImplicitCheckJs ?? true;
    if (isJs && !implicitCheckJs) {
      return const [];
    }

    final override = debugResolverOverride;
    final tsc = override?.tsc ?? await BundledLanguageServers.instance.tscJsPath();
    if (tsc == null) return const [];
    final node = override?.node ??
        await BundledLanguageServers.instance.findNodeExecutable();
    if (node == null) return const [];

    // 全局队列：同一时刻最多 2 个 tsc 进程，超出排队，防止多进程轰炸。
    // E2：等待者上限 8——此前忙等无界，洪水调用全部滞留排队撑内存；
    // 等待者超上限直接放弃（返回空结果，语义同失败兜底）。
    while (_inflight >= 2) {
      if (_waiters >= 8) {
        // D6-L18：过载放弃必须可观测——此前静默返回空，洪水调用下
        // 诊断无声丢失无从排查。
        AppLogger.instance.warn(
          'local:tsc',
          'tsc 等待队列已满（>=8），放弃本次检查：$filePath',
        );
        return const [];
      }
      _waiters++;
      try {
        await Future.delayed(const Duration(milliseconds: 200));
      } finally {
        _waiters--;
      }
    }
    _inflight++;
    try {
      final projectConfig = _findProjectTsConfig(projectRoot ?? p.dirname(filePath));
      // 优先用项目 tsconfig/jsconfig 里的 paths/types/moduleResolution，避免 default 设置与大仓冲突。
      final useProjectConfig = projectConfig != null;
      // 内存/临时虚拟工程：只写系统临时目录，绝不碰用户项目根。
      Directory? tmpDir;
      File? tmpFile;
      try {
        tmpDir = await Directory.systemTemp.createTemp('my_ide_tsc_');
        final base = p.basename(filePath);
        tmpFile = File(p.join(tmpDir.path, base.isEmpty ? 'file.js' : base));
        await tmpFile.writeAsString(text);
        var filterToTempFile = false;
        // 项目无配置时补虚拟 jsconfig；有配置时生成继承项目 tsconfig 的
        // 临时工程，不再临时伪配置。
        if (useProjectConfig) {
          // `--project` 不能与源文件参数混用，否则 tsc 报 TS5042 直接拒绝
          // 执行（旧实现因此恒返回空）。改为临时工程继承项目 tsconfig：
          // extends 复用 paths/types；include 必须显式置空（父配置 include
          // 会被 union 继承，连带检查整个项目），files 用相对临时工程目录
          // 的裸文件名（字面量，无 glob 语义；绝对路径在 /tmp 等符号链接
          // 目录下会被 tsc 静默匹配不到任何输入）。
          filterToTempFile = true;
          await File(p.join(tmpDir.path, 'tsconfig.my_ide_check.json'))
              .writeAsString(const JsonEncoder.withIndent('  ').convert({
            'extends': projectConfig,
            'compilerOptions': {
              'noEmit': true,
              // 防止继承 incremental/composite 后往用户项目写 .tsbuildinfo。
              'incremental': false,
              'composite': false,
              if (isJs) ...const {'allowJs': true, 'checkJs': true},
            },
            'include': <String>[],
            'files': [base.isEmpty ? 'file.js' : base],
          }));
        } else if (isJs) {
          await File(p.join(tmpDir.path, 'jsconfig.json')).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'compilerOptions': {
                'checkJs': true,
                'allowJs': true,
                'noEmit': true,
                'target': 'ES2020',
                'module': 'ESNext',
                'moduleResolution': 'bundler',
                'skipLibCheck': true,
              },
              'include': [base.isEmpty ? 'file.js' : base],
            }),
          );
        }
        final args = <String>[
          tsc,
          '--pretty',
          'false',
          '--noEmit',
          if (useProjectConfig) ...[
            '--project',
            p.join(tmpDir.path, 'tsconfig.my_ide_check.json'),
          ],
          if (!useProjectConfig) ...[
            '--target',
            'ES2020',
            '--module',
            'ESNext',
            '--moduleResolution',
            'bundler',
            if (isJs) ...['--allowJs', '--checkJs'],
            // 项目模式下不能再追加源文件参数（与 --project 互斥，TS5042）。
            tmpFile.path,
          ],
        ];
        // E2：Process.run(...).timeout 超时后子进程仍在跑（run 不杀进程），
        // hang 的 tsc 常驻占并发槽。改 Process.start，超时 sigkill 并
        // await exitCode 收尸；超时返回空结果，语义不变。
        final proc = await Process.start(
          node,
          args,
          workingDirectory: tmpDir.path,
          environment: BundledLanguageServers.instance.processEnvironment(),
        );
        final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
        final stderrFuture = proc.stderr.transform(utf8.decoder).join();
        String stdoutText;
        String stderrText;
        try {
          await proc.exitCode.timeout(const Duration(seconds: 12));
          stdoutText = await stdoutFuture;
          stderrText = await stderrFuture;
        } on TimeoutException {
          try {
            proc.kill(ProcessSignal.sigkill);
          } catch (_) {}
          // 收尸防僵尸；进程死后管道 EOF，join 自然完成。
          await proc.exitCode;
          return const [];
        }

        final out = '$stdoutText\n$stderrText';
        return _parseTscOutput(
          output: out,
          originalPath: filePath,
          tempPath: tmpFile.path,
          contentVersion: contentVersion,
          text: text,
          filterToTempFile: filterToTempFile,
        );
      } catch (_) {
        return const [];
      } finally {
        try {
          await tmpDir?.delete(recursive: true);
        } catch (_) {}
      }
    } finally {
      _inflight--;
    }
  }

  /// 向上查找项目/目录级 tsconfig.json 或 jsconfig.json，复用其中的 paths/types。
  /// 返回 null 表示项目未配置，无需再让 tsc 起临时虚拟工程。
  /// R-TSCONFIG-CACHE：结果按 (startDir→config) 缓存 60s——此前每轮分析
  /// 最多 64 次 existsSync 同步 IO，大仓深层路径每轮叠加微卡顿。
  /// 文件 TTL 内被删除的兜底：非 null 命中后仍存在性复检一次（单次 stat）。
  /// A4-11：null 命中（此前无配置）同样做存在性复检——项目中途新建
  /// tsconfig 后，若直接返回缓存 null，TTL 内仍按"无配置"跑，新配置
  /// 60s 不生效。null 命中重跑一次向上查找（existsSync 链为微秒级，
  /// 远低于 tsc 起进程成本，正确性优先）并刷新时间戳。
  static final Map<String, (String?, DateTime)> _tsConfigCache = {};
  static String? _findProjectTsConfig(String startDir) {
    final cached = _tsConfigCache[startDir];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(seconds: 60)) {
      final hit = cached.$1;
      if (hit != null) {
        if (File(hit).existsSync()) return hit;
      } else {
        final recheck = _scanTsConfigUpward(startDir);
        _tsConfigCache[startDir] = (recheck, DateTime.now());
        return recheck;
      }
    }
    final found = _scanTsConfigUpward(startDir);
    _tsConfigCache[startDir] = (found, DateTime.now());
    if (_tsConfigCache.length > 256) _tsConfigCache.clear();
    return found;
  }

  /// 向上扫描 tsconfig/jsconfig（最多 32 层），返回首个命中路径或 null。
  static String? _scanTsConfigUpward(String startDir) {
    var dir = Directory(startDir);
    for (var depth = 0; depth < 32 && dir.path.isNotEmpty; depth++) {
      for (final name in const ['tsconfig.json', 'jsconfig.json']) {
        final candidate = File(p.join(dir.path, name));
        if (candidate.existsSync()) return candidate.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// A4-11 测试钩子：暴露 _findProjectTsConfig（含缓存与 null 命中复检）
  /// 供回归——生产路径经 analyze(projectRoot) 调用。
  @visibleForTesting
  static String? findProjectTsConfigForTest(String startDir) =>
      _findProjectTsConfig(startDir);

  static List<IdeDiagnostic> _parseTscOutput({
    required String output,
    required String originalPath,
    required String tempPath,
    required int contentVersion,
    required String text,
    bool filterToTempFile = false,
  }) {
    final lines = text.split('\n');
    final maxLine = (lines.isEmpty ? 0 : lines.length - 1);
    final out = <IdeDiagnostic>[];
    // bad.js(3,3): error TS2552: Cannot find name 'consle'. Did you mean 'console'?
    final re = RegExp(
      r'^(.+?)(?:\(|:)(\d+)(?:,|:)(\d+)\)?:\s*(error|warning|info)\s+(TS\d+):\s*(.+)$',
      multiLine: true,
      caseSensitive: false,
    );
    for (final match in re.allMatches(output)) {
      // 项目配置模式下临时工程会连带编译 import 的依赖文件：其错误路径
      // 带目录段或为绝对路径，只有直接位于 cwd（临时目录）的临时文件保留。
      // 注意输出路径形态随调用方式变化：裸文件名、./name、甚至 ../ 链
      // （绝对 --project + 绝对 extends 时 tsc 以相对 cwd 的 ../ 链打印），
      // 统一按 cwd 归一化后与临时文件比对，不能只认裸文件名。
      var reportedFile = (match.group(1) ?? '').trim();
      if (reportedFile.startsWith('./')) {
        reportedFile = reportedFile.substring(2);
      }
      if (filterToTempFile) {
        final normalized = p.canonicalize(p.normalize(
          p.isAbsolute(reportedFile)
              ? reportedFile
              : p.join(p.dirname(tempPath), reportedFile),
        ));
        if (normalized != p.canonicalize(tempPath)) {
          continue;
        }
      }
      final line = ((int.tryParse(match.group(2) ?? '1') ?? 1) - 1)
          .clamp(0, maxLine);
      final col = ((int.tryParse(match.group(3) ?? '1') ?? 1) - 1)
          .clamp(0, lines.isEmpty ? 0 : lines[line].length);
      final kind = (match.group(4) ?? 'error').toLowerCase();
      final code = match.group(5);
      final message = (match.group(6) ?? '').trim();
      if (message.isEmpty) continue;
      final endCol = (col + 1).clamp(col, lines.isEmpty ? col : lines[line].length);
      out.add(IdeDiagnostic(
        filePath: originalPath,
        startLine: line,
        startChar: col,
        endLine: line,
        endChar: endCol,
        severity: kind == 'warning'
            ? DiagnosticSeverity.warning
            : kind == 'info'
                ? DiagnosticSeverity.info
                : DiagnosticSeverity.error,
        message: message,
        source: source,
        code: code,
        contentVersion: contentVersion,
      ));
    }
    return out;
  }
}
