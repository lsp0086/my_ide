import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/command_process_manager.dart';

void main() {
  late Directory workspace;
  late CommandProcessManager manager;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('command-process-');
    manager = CommandProcessManager();
  });

  tearDown(() async {
    await manager.dispose();
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('terminateAll 终止命令及其子进程', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/child-finished');
    await manager.start('/bin/sh', [
      '-c',
      '(sleep 2; echo escaped > child-finished) & wait',
    ], workingDirectory: workspace.path);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(manager.activeCount, 1);
    await manager.terminateAll();
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('前台命令超时后停止进程树和后续文件写入', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/timeout-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);

    final result = await tools.executeCommand(
      {
        'command': '(sleep 6; echo escaped > timeout-escaped) & wait',
        'timeout': 5,
      },
      sessionId: 'session-timeout',
      allowShell: true,
    );
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(result.ok, isFalse);
    expect(result.output, contains('命令执行超时'));
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('后台任务可跨调用增量轮询并隔离会话', () async {
    if (Platform.isWindows) return;
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'echo first; sleep 1; echo second',
        'background': true,
        'timeout': 10,
      },
      sessionId: 'session-a',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;

    final denied = await tools.pollTask({'taskId': id}, sessionId: 'session-b');
    expect(denied.ok, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final first = await tools.pollTask({'taskId': id}, sessionId: 'session-a');
    expect(first.output, contains('first'));

    final repeated = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-a');
    expect(repeated.output, contains('暂无新增输出'));

    await Future<void>.delayed(const Duration(seconds: 2));
    final finished = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-a');
    expect(finished.output, contains('second'));
    expect(finished.output, contains('已退出 exit=0'));
  });

  test('kill 后台任务后停止后续副作用', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/background-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'sleep 2; echo escaped > background-escaped',
        'background': true,
        'timeout': 10,
      },
      sessionId: 'session-kill',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;

    final killed = await tools.pollTask({
      'taskId': id,
      'kill': true,
    }, sessionId: 'session-kill');
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(killed.ok, isTrue);
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('后台任务超时后停止进程树和后续文件写入', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/bg-timeout-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'sleep 8; echo escaped > bg-timeout-escaped',
        'background': true,
        'timeout': 5,
      },
      sessionId: 'session-bg-timeout',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;
    await Future<void>.delayed(const Duration(seconds: 8));
    final polled = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-bg-timeout');

    expect(polled.output, contains('已退出'));
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('会话清理后后台任务不可再轮询且进程已停止', () async {
    if (Platform.isWindows) return;
    final marker = File('${workspace.path}/session-escaped');
    final tools = AgentTools(rootPath: workspace.path, processManager: manager);
    final started = await tools.executeCommand(
      {
        'command': 'sleep 4; echo escaped > session-escaped',
        'background': true,
        'timeout': 30,
      },
      sessionId: 'session-clean',
      allowShell: true,
    );
    final id = RegExp(r'bg-[0-9-]+').firstMatch(started.output)!.group(0)!;
    await tools.disposeBackgroundTasks(sessionId: 'session-clean');
    await Future<void>.delayed(const Duration(seconds: 5));
    final missing = await tools.pollTask({
      'taskId': id,
    }, sessionId: 'session-clean');

    expect(missing.ok, isFalse);
    expect(manager.activeCount, 0);
    expect(await marker.exists(), isFalse);
  });

  test('terminate 先优雅终止再清理句柄', () async {
    if (Platform.isWindows) return;
    final process = await manager.start('/bin/sh', [
      '-c',
      'sleep 30',
    ], workingDirectory: workspace.path);

    await manager.terminate(
      process,
      gracePeriod: const Duration(milliseconds: 100),
    );

    expect(manager.activeCount, 0);
  });
}
