import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// 启动环境自检的结果严重程度。
enum CheckSeverity {
  /// 不满足就禁止启动，并明确告知缺什么。
  required,

  /// 不满足只给提示，不阻塞（例如 ffmpeg 缺失回落内置 fMP4 合并）。
  optional,
}

/// 单条检查结果。
class CheckResult {
  const CheckResult({
    required this.id,
    required this.labelKey,
    required this.ok,
    required this.severity,
    this.detail,
  });

  /// 稳定标识，界面用它判断是不是 WebView2 失败（决定是否给安装入口）。
  final String id;

  /// 文案表里的键，界面按当前语言取标题。
  final String labelKey;

  final bool ok;
  final CheckSeverity severity;

  /// 失败时的具体原因（原始文本，可能含系统错误信息），成功时为 null。
  final String? detail;

  bool get isBlocking => !ok && severity == CheckSeverity.required;
}

/// 全部启动检查结果。
class StartupReport {
  const StartupReport(this.results);

  final List<CheckResult> results;

  /// 所有必需项都通过。
  bool get allRequiredOk => results
      .where((r) => r.severity == CheckSeverity.required)
      .every((r) => r.ok);

  /// 阻塞启动的失败项。
  List<CheckResult> get blocking =>
      results.where((r) => r.isBlocking).toList();

  /// 仅作提示的非阻塞失败项。
  List<CheckResult> get warnings => results
      .where((r) => !r.ok && r.severity == CheckSeverity.optional)
      .toList();
}

/// 外部探针：真实运行走系统，测试可整体注入，保证单元化、不碰本机。
typedef StartupProbe = Future<CheckResult> Function();

/// 运行 Windows 启动环境自检。
///
/// 只检查「软件自身依赖」：数据目录可建可写、应用资源可读、WebView2 运行时可用。
/// 三者任一缺失都禁止启动并明确告知。ffmpeg 属可选（缺失回落内置 fMP4 合并），
/// 不在此阻塞。
///
/// [dataRoot] 待校验的用户数据根目录；[isWindows] 决定是否检查 WebView2；
/// [assetsProbe]/[webView2Probe] 默认走系统，测试可注入。
Future<StartupReport> runStartupChecks({
  required Directory dataRoot,
  bool isWindows = false,
  StartupProbe? assetsProbe,
  StartupProbe? webView2Probe,
}) async {
  final results = <CheckResult>[];
  results.add(await _checkDataDir(dataRoot));
  results.add(await (assetsProbe ?? _defaultAssetsProbe)());
  if (isWindows) {
    results.add(await (webView2Probe ?? _defaultWebView2Probe)());
  }
  return StartupReport(results);
}

Future<CheckResult> _checkDataDir(Directory dir) async {
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final probe =
        File('${dir.path}${Platform.pathSeparator}._startup_check_');
    probe.writeAsStringSync('ok');
    final read = probe.readAsStringSync();
    probe.deleteSync();
    if (read != 'ok') {
      return const CheckResult(
        id: 'dataDir',
        labelKey: 'startup.check.dataDir',
        ok: false,
        severity: CheckSeverity.required,
        detail: '数据目录可写但回读内容不符',
      );
    }
    return const CheckResult(
      id: 'dataDir',
      labelKey: 'startup.check.dataDir',
      ok: true,
      severity: CheckSeverity.required,
    );
  } on Object catch (error) {
    return CheckResult(
      id: 'dataDir',
      labelKey: 'startup.check.dataDir',
      ok: false,
      severity: CheckSeverity.required,
      detail: _brief(error),
    );
  }
}

Future<CheckResult> _defaultAssetsProbe() async {
  try {
    final manifest = await rootBundle.loadString('AssetManifest.json');
    if (manifest.isEmpty) {
      return const CheckResult(
        id: 'assets',
        labelKey: 'startup.check.assets',
        ok: false,
        severity: CheckSeverity.required,
        detail: '资源清单为空',
      );
    }
    return const CheckResult(
      id: 'assets',
      labelKey: 'startup.check.assets',
      ok: true,
      severity: CheckSeverity.required,
    );
  } on Object catch (error) {
    return CheckResult(
      id: 'assets',
      labelKey: 'startup.check.assets',
      ok: false,
      severity: CheckSeverity.required,
      detail: _brief(error),
    );
  }
}

/// WebView2 运行时在注册表里的客户端 GUID（Evergreen 运行时）。
const String _webView2ClientGuid = '{F3017226-FE2A-4295-8BDF-00C3A9A08C11}';

Future<CheckResult> _defaultWebView2Probe() async {
  const wow = 'Software\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\';
  final keys = <String>[
    'HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\$_webView2ClientGuid',
    'HKLM\\Software\\Microsoft\\EdgeUpdate\\Clients\\$_webView2ClientGuid',
    'HKLM\\$wow$_webView2ClientGuid',
  ];
  for (final key in keys) {
    try {
      final result = await Process.run(
        'reg',
        <String>['query', key, '/v', 'pv'],
      );
      final out = result.stdout.toString();
      if (result.exitCode == 0 && out.contains('pv')) {
        return const CheckResult(
          id: 'webview2',
          labelKey: 'startup.check.webview2',
          ok: true,
          severity: CheckSeverity.required,
        );
      }
    } on ProcessException {
      // reg 不可用，试下一个位置。
    }
  }
  return const CheckResult(
    id: 'webview2',
    labelKey: 'startup.check.webview2',
    ok: false,
    severity: CheckSeverity.required,
    detail: '未检测到 WebView2 运行时',
  );
}

/// 把系统异常压成一行短文本：过长截断，避免泄露路径细节也避免刷屏。
String _brief(Object error) {
  final text = '$error';
  return text.length > 120 ? '${text.substring(0, 117)}…' : text;
}
