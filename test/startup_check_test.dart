import 'dart:io';

import 'package:bilicross/src/core/startup_check.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个总是通过的探针。
StartupProbe _ok(String id, String labelKey,
        [CheckSeverity severity = CheckSeverity.required]) =>
    () async => CheckResult(
          id: id,
          labelKey: labelKey,
          ok: true,
          severity: severity,
        );

/// 造一个总是失败的探针。
StartupProbe _bad(
  String id,
  String labelKey, {
  CheckSeverity severity = CheckSeverity.required,
  String detail = '探针失败',
}) =>
    () async => CheckResult(
          id: id,
          labelKey: labelKey,
          ok: false,
          severity: severity,
          detail: detail,
        );

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('bilicross_startup_');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('数据目录不存在时会创建，并写读删一次自检文件', () async {
    final sep = Platform.pathSeparator;
    final target = Directory(
      '${sandbox.path}${sep}nested${sep}data',
    );
    expect(target.existsSync(), isFalse);

    final report = await runStartupChecks(
      dataRoot: target,
      assetsProbe: _ok('assets', 'startup.check.assets'),
    );

    expect(target.existsSync(), isTrue);
    final dataCheck = report.results.firstWhere((r) => r.id == 'dataDir');
    expect(dataCheck.ok, isTrue);
    expect(dataCheck.detail, isNull);
    expect(report.allRequiredOk, isTrue);
    expect(report.blocking, isEmpty);
    // 自检文件必须清干净，不能留在用户数据目录里。
    final leftovers = target
        .listSync()
        .where((e) => e.path.contains('._startup_check_'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('数据目录不可写时判定为阻塞项，并带上原因', () async {
    // 用一个「文件」充当目录，createSync 必然失败。
    final blocked = File('${sandbox.path}${Platform.pathSeparator}blocked');
    blocked.writeAsStringSync('x');

    final report = await runStartupChecks(
      dataRoot: Directory(blocked.path),
      assetsProbe: _ok('assets', 'startup.check.assets'),
    );

    final dataCheck = report.results.firstWhere((r) => r.id == 'dataDir');
    expect(dataCheck.ok, isFalse);
    expect(dataCheck.isBlocking, isTrue);
    expect(dataCheck.detail, isNotNull);
    expect(report.allRequiredOk, isFalse);
    expect(report.blocking.map((r) => r.id), contains('dataDir'));
  });

  test('资源探针失败会让必需项不通过', () async {
    final report = await runStartupChecks(
      dataRoot: sandbox,
      assetsProbe: _bad('assets', 'startup.check.assets', detail: '清单为空'),
    );

    expect(report.allRequiredOk, isFalse);
    final assets = report.results.firstWhere((r) => r.id == 'assets');
    expect(assets.ok, isFalse);
    expect(assets.detail, '清单为空');
  });

  test('非 Windows 不检查 WebView2', () async {
    final report = await runStartupChecks(
      dataRoot: sandbox,
      isWindows: false,
      assetsProbe: _ok('assets', 'startup.check.assets'),
      webView2Probe: _bad('webview2', 'startup.check.webview2'),
    );

    expect(report.results.any((r) => r.id == 'webview2'), isFalse);
    expect(report.allRequiredOk, isTrue);
  });

  test('Windows 上缺 WebView2 会阻塞启动', () async {
    final report = await runStartupChecks(
      dataRoot: sandbox,
      isWindows: true,
      assetsProbe: _ok('assets', 'startup.check.assets'),
      webView2Probe:
          _bad('webview2', 'startup.check.webview2', detail: '未检测到运行时'),
    );

    expect(report.allRequiredOk, isFalse);
    expect(report.blocking.map((r) => r.id), contains('webview2'));
  });

  test('Windows 上三项齐全则通过', () async {
    final report = await runStartupChecks(
      dataRoot: sandbox,
      isWindows: true,
      assetsProbe: _ok('assets', 'startup.check.assets'),
      webView2Probe: _ok('webview2', 'startup.check.webview2'),
    );

    expect(report.results.length, 3);
    expect(report.allRequiredOk, isTrue);
    expect(report.blocking, isEmpty);
    expect(report.warnings, isEmpty);
  });

  test('可选失败只算提示，不阻塞启动', () async {
    final report = await runStartupChecks(
      dataRoot: sandbox,
      isWindows: true,
      assetsProbe: _ok('assets', 'startup.check.assets'),
      webView2Probe: _ok('webview2', 'startup.check.webview2'),
    );
    final withOptional = StartupReport([
      ...report.results,
      const CheckResult(
        id: 'ffmpeg',
        labelKey: 'startup.check.ffmpeg',
        ok: false,
        severity: CheckSeverity.optional,
        detail: '未找到 ffmpeg，改用内置合并',
      ),
    ]);

    expect(withOptional.allRequiredOk, isTrue);
    expect(withOptional.blocking, isEmpty);
    expect(withOptional.warnings.map((r) => r.id), contains('ffmpeg'));
  });

  test('成功项不带原因，失败项才有', () async {
    final report = await runStartupChecks(
      dataRoot: sandbox,
      assetsProbe: _ok('assets', 'startup.check.assets'),
    );

    for (final item in report.results) {
      if (item.ok) {
        expect(item.detail, isNull);
      }
    }
  });
}
