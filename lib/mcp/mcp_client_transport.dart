part of 'mcp_client.dart';

/// 传输域：进程组探测、stdio/HTTP 建连、桌面 PATH 环境
extension _McpSessionTransportExt on McpSession {

  /// 查询指定 pid 的进程组 id，失败返回 null（ps 不可用时调用方跳过组杀）。
  Future<int?> _pgidOf(int queryPid) async {
    try {
      final result = await Process.run(
        'ps',
        ['-o', 'pgid=', '-p', '$queryPid'],
      ).timeout(const Duration(seconds: 2));
      if (result.exitCode != 0) return null;
      final raw = '${result.stdout}'.trim().split(RegExp(r'\s+')).firstWhere(
            (e) => e.isNotEmpty,
            orElse: () => '',
          );
      return int.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _connectStdio() async {
    final command = config.command.trim();
    if (command.isEmpty) {
      throw StateError('stdio 服务器未配置 command');
    }
    // 环境最小化：不再合并全量 Platform.environment，只给 PATH + 必要项，
    // 密钥靠 config.env 显式传入，避免泄漏宿主全部环境变量。
    // env/headers 支持 ${ENV:VAR} / ${VAR} 本地展开。
    final expandedEnv = McpConfigImporter.expandEnvMap(config.env);
    final env = <String, String>{
      ..._desktopPathEnv(),
      ...McpSession._minimalEnv(),
      ...expandedEnv,
    };
    // 测试钩子：可注入假进程（假 stdin/stdout 流），生产路径走 Process.start。
    final factory = McpSession.processFactoryForTest;
    if (factory != null) {
      _process = await factory(command, config.args);
    } else {
      // stdio 生命周期结算（stdin.close / exitCode 崩溃监听 / 组杀等待退出）
      // 全部依赖 exitCode——detached/detachedWithStdio 的 exitCode getter
      // 会抛 StateError（dart:io 明确文档），此前 detachedWithStdio 使生产
      // 路径一连接即炸（测试走 McpSession.processFactoryForTest 假进程未暴露）。
      // 现 POSIX 有 /usr/bin/setsid 时经其新起会话（normal 模式：非组长
      // 不 fork，stdio/exitCode 全可用，子进程自成一_session，disconnect
      // 的 pgid 校验组杀照常生效）；缺失/Windows 回退普通启动。
      if (!Platform.isWindows) {
        try {
          _process = await Process.start(
            '/usr/bin/setsid',
            [command, ...config.args],
            workingDirectory:
                (config.cwd != null && config.cwd!.trim().isNotEmpty)
                    ? config.cwd
                    : null,
            environment: env,
            includeParentEnvironment: false,
          );
        } catch (_) {
          _process = null;
        }
      }
      _process ??= await Process.start(
        command,
        config.args,
        workingDirectory:
            (config.cwd != null && config.cwd!.trim().isNotEmpty)
                ? config.cwd
                : null,
        environment: env,
        includeParentEnvironment: false,
      );
    }
    _stdoutSub = _process!.stdout.listen(_onStdioBytes);
    // 退出监听：崩溃后 connected 置 false，不再谎报在线。
    _process!.exitCode.then((code) {
      if (_process == null) return;
      _connected = false;
      _lastError = 'MCP 进程已退出（code=$code），请重连';
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.completeError(StateError('MCP 进程已退出'));
        }
      }
      _pending.clear();
    });
    _stderrSub = _process!.stderr.listen((bytes) {
      // stderr 仅作诊断，不参与协议
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isNotEmpty) {
        // D6：stderr 原文脱敏后才进 _lastError——网关/代理回显的
        // Authorization 头等凭据不得原样进入错误态（并经 manager
        // _lastFailure 持久化 prefs）。先截断再脱敏，防截断切坏掩码。
        final clipped = text.length > 400 ? text.substring(0, 400) : text;
        _lastError = McpSession.redactSecrets(clipped);
        _appendLog('stderr: $text');
      }
    });
  }

  Future<void> _connectHttp() async {
    final url = config.url.trim();
    if (url.isEmpty) throw StateError('HTTP 服务器未配置 url');
    _http = http.Client();
  }

  Map<String, String> _desktopPathEnv() {
    final path = Platform.environment['PATH'] ?? '';
    const extras = [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ];
    final parts = <String>{
      ...path.split(':').where((e) => e.isNotEmpty),
      ...extras,
    };
    return {'PATH': parts.join(':')};
  }
}
