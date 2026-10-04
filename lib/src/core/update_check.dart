import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'device_identity.dart';

/// 项目主页：关于弹窗的「项目地址」与更新跳转都用它。
const String kProjectUrl = 'https://github.com/molakesizhanfangguangmang/bilicross';

/// 没有可用直链时的兜底地址（Release 列表页）。
const String kReleaseListUrl = '$kProjectUrl/releases';

/// 更新配置接口：由服务端手动维护版本号、更新说明与下载直链，
/// 下载仍指向 GitHub Release 资产。
const String kUpdateConfigApi = 'https://bili.culture-see.de5.net/v1/update';

const Duration kUpdateCheckTimeout = Duration(seconds: 8);

enum UpdateOutcome {
  /// 远端有更新的正式版。
  available,

  /// 已经是最新（远端版本号不高于本地）。
  upToDate,

  /// 没查到结果：网络不通、响应异常、版本号读不出来。
  failed,
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.outcome,
    this.currentVersion = '',
    this.latestVersion = '',
    this.releaseUrl = kReleaseListUrl,
    this.notes = '',
    this.assets = const <ReleaseAsset>[],
    this.minVersion = '',
    this.forceUpdate = false,
    this.rollout = false,
    this.tokenRequired = false,
    this.file = '',
  });

  final UpdateOutcome outcome;

  /// 本机安装包的版本号，例如 `1.0.1`。
  final String currentVersion;

  /// 远端 Release 的 tag，例如 `v1.0.2`。
  final String latestVersion;

  final String releaseUrl;

  /// Release 说明原文（Markdown），可能为空。
  final String notes;

  /// 该 Release 附带的产物列表，用于按平台挑下载直链。
  final List<ReleaseAsset> assets;

  /// 低于该版本时不可关闭（服务端下发，空串＝不强制）。
  final String minVersion;

  /// 本次更新是否不可关闭（由 [minVersion] 与当前版本比较得出）。
  final bool forceUpdate;

  /// 本次更新是否来自灰度名单（按设备下发）。
  final bool rollout;

  /// 灰度内测包下载是否需要填 token。
  final bool tokenRequired;

  /// 灰度内测包文件名；非空表示走 VPS 下载接口。
  final String file;

  /// 展示用的远端版本号，保证带 `v` 前缀。
  String get latestLabel {
    if (latestVersion.isEmpty) return latestVersion;
    final first = latestVersion[0];
    if (first == 'v' || first == 'V') return latestVersion;
    return 'v$latestVersion';
  }
}

/// Release 里的一个产物文件。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.sizeBytes = 0,
    this.sha256 = '',
  });

  final String name;
  final String downloadUrl;
  final int sizeBytes;

  /// 该产物的 SHA-256。GitHub 的产物接口带 `digest` 字段时才有值。
  final String sha256;

  /// 下载体积的展示文本；大小为 0 时返回空串。
  String get readableSize {
    if (sizeBytes <= 0) return '';
    final mb = sizeBytes / 1024 / 1024;
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
    return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  bool get isChecksum => name.toLowerCase().endsWith('.sha256');
}

/// 把 GitHub 产物接口里的 `digest` 字段规整成纯十六进制，认不出返回空串。
///
/// 接口可能返回 `sha256:<hex>` 也可能直接给 `<hex>`，这里两种都接得住；
/// 只要拿不到 64 位十六进制就当没有，不硬凑。
String normalizeChecksum(Object? raw) {
  if (raw is! String) return '';
  var value = raw.trim();
  final cut = value.lastIndexOf(':');
  if (cut >= 0) value = value.substring(cut + 1).trim();
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) return '';
  return value.toLowerCase();
}

/// 版本号只比数字段：去掉 `v` 前缀，丢掉 `+构建号` 与 `-预发布` 后缀。
List<int> parseVersionNumbers(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return const <int>[];
  final first = text[0];
  if (first == 'v' || first == 'V') text = text.substring(1);
  final cut = text.indexOf(RegExp(r'[+\-]'));
  if (cut >= 0) text = text.substring(0, cut);
  final numbers = <int>[];
  for (final part in text.split('.')) {
    final value = int.tryParse(part.trim());
    if (value == null) break;
    numbers.add(value);
  }
  return numbers;
}

/// 远端版本是否比本地新。相等、缺段、解析不出来都算不是。
bool isRemoteNewer(String remote, String local) {
  final remoteParts = parseVersionNumbers(remote);
  final localParts = parseVersionNumbers(local);
  if (remoteParts.isEmpty || localParts.isEmpty) return false;
  final length = remoteParts.length > localParts.length
      ? remoteParts.length
      : localParts.length;
  for (var i = 0; i < length; i++) {
    final right = i < remoteParts.length ? remoteParts[i] : 0;
    final left = i < localParts.length ? localParts[i] : 0;
    if (right != left) return right > left;
  }
  return false;
}

/// 从 `releases/latest` 的响应体里取出 tag 与页面地址，取不到返回 null。
Map<String, String>? readLatestRelease(Object? payload) {
  if (payload is! Map) return null;
  final tag = payload['tag_name'];
  if (tag is! String || tag.trim().isEmpty) return null;
  final url = payload['html_url'];
  return <String, String>{
    'version': tag.trim(),
    'url': url is String && url.trim().isNotEmpty ? url.trim() : kReleaseListUrl,
  };
}

/// 取 Release 说明原文。GitHub 返回的 `body` 就是 Markdown 说明。
String readReleaseNotes(Object? payload) {
  if (payload is! Map) return '';
  final body = payload['body'];
  return body is String ? body.trim() : '';
}

/// 取 Release 附带的产物列表。结构异常或字段缺失的条目直接跳过。
List<ReleaseAsset> readReleaseAssets(Object? payload) {
  if (payload is! Map) return const <ReleaseAsset>[];
  final raw = payload['assets'];
  if (raw is! List) return const <ReleaseAsset>[];
  final assets = <ReleaseAsset>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final name = item['name'];
    final url = item['browser_download_url'];
    if (name is! String || url is! String) continue;
    if (name.trim().isEmpty || url.trim().isEmpty) continue;
    final size = item['size'];
    final digest = item['digest'];
    assets.add(
      ReleaseAsset(
        name: name.trim(),
        downloadUrl: url.trim(),
        sizeBytes: size is num ? size.toInt() : 0,
        sha256: normalizeChecksum(digest),
      ),
    );
  }
  return assets;
}

/// 把一次 Release 响应折算成检查结果（纯函数，便于离线自测）。
UpdateCheckResult resultFromRelease(Object? payload, String currentVersion) {
  final release = readLatestRelease(payload);
  if (release == null) {
    return UpdateCheckResult(
      outcome: UpdateOutcome.failed,
      currentVersion: currentVersion,
    );
  }
  final latest = release['version'] ?? '';
  if (isRemoteNewer(latest, currentVersion)) {
    return UpdateCheckResult(
      outcome: UpdateOutcome.available,
      currentVersion: currentVersion,
      latestVersion: latest,
      releaseUrl: release['url'] ?? kReleaseListUrl,
      notes: readReleaseNotes(payload),
      assets: readReleaseAssets(payload),
    );
  }
  return UpdateCheckResult(
    outcome: UpdateOutcome.upToDate,
    currentVersion: currentVersion,
    latestVersion: latest,
  );
}

/// 服务端下发的更新配置。字段白名单由服务端保证，这里按字符串收下，
/// 认不出或缺失就回落到「没有更新」。
class UpdateConfig {
  const UpdateConfig({
    required this.version,
    required this.notes,
    required this.androidUrl,
    required this.windowsSetupUrl,
    required this.windowsPortableUrl,
    required this.minVersion,
    required this.rollout,
    required this.tokenRequired,
    required this.file,
  });

  final String version;
  final String notes;
  final String androidUrl;
  final String windowsSetupUrl;
  final String windowsPortableUrl;
  final String minVersion;
  final bool rollout;
  final bool tokenRequired;
  final String file;

  static UpdateConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = '${raw['version'] ?? ''}'.trim();
    if (version.isEmpty) return null;
    return UpdateConfig(
      version: version,
      notes: '${raw['notes'] ?? ''}'.trim(),
      androidUrl: '${raw['androidUrl'] ?? ''}'.trim(),
      windowsSetupUrl: '${raw['windowsSetupUrl'] ?? ''}'.trim(),
      windowsPortableUrl: '${raw['windowsPortableUrl'] ?? ''}'.trim(),
      minVersion: '${raw['minVersion'] ?? ''}'.trim(),
      rollout: raw['rollout'] == true,
      tokenRequired: raw['tokenRequired'] == true,
      file: '${raw['file'] ?? ''}'.trim(),
    );
  }
}

/// 把服务端的更新配置折算成检查结果（纯函数，便于离线自测）。
UpdateCheckResult resultFromUpdateConfig(Object? payload, String currentVersion) {
  if (payload is! Map) {
    return UpdateCheckResult(
      outcome: UpdateOutcome.failed,
      currentVersion: currentVersion,
    );
  }
  final config = UpdateConfig.fromJson(payload['update']);
  if (config == null) {
    return UpdateCheckResult(
      outcome: UpdateOutcome.failed,
      currentVersion: currentVersion,
    );
  }
  final latest = config.version;
  if (!isRemoteNewer(latest, currentVersion)) {
    return UpdateCheckResult(
      outcome: UpdateOutcome.upToDate,
      currentVersion: currentVersion,
      latestVersion: latest,
    );
  }
  final minVersion = config.minVersion;
  final forceUpdate = minVersion.isNotEmpty && isRemoteNewer(minVersion, currentVersion);
  final assets = <ReleaseAsset>[
    if (config.androidUrl.isNotEmpty)
      ReleaseAsset(
        name: 'BiliCross-$latest-android-arm64.apk',
        downloadUrl: config.androidUrl,
      ),
    if (config.windowsSetupUrl.isNotEmpty)
      ReleaseAsset(
        name: 'BiliCross-$latest-windows-x64-setup.exe',
        downloadUrl: config.windowsSetupUrl,
      ),
    if (config.windowsPortableUrl.isNotEmpty)
      ReleaseAsset(
        name: 'BiliCross-$latest-windows-x64-portable.zip',
        downloadUrl: config.windowsPortableUrl,
      ),
  ];
  return UpdateCheckResult(
    outcome: UpdateOutcome.available,
    currentVersion: currentVersion,
    latestVersion: latest,
    releaseUrl: kReleaseListUrl,
    notes: config.notes,
    assets: assets,
    minVersion: minVersion,
    forceUpdate: forceUpdate,
    rollout: config.rollout,
    tokenRequired: config.tokenRequired,
    file: config.file,
  );
}

/// 本机安装包的版本号。读不出来返回空串，调用方按「检测失败」处理。
Future<String> readCurrentVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } catch (_) {
    return '';
  }
}

/// 本机安装包的包名（`applicationId`）。内测包以 `.test` 结尾 —— 服务端靠这个
/// 后缀分辨内测 / 正式版的提交。读不出来返回空串。
Future<String> readPackageName() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.packageName;
  } catch (_) {
    return '';
  }
}

/// 查一次最新正式版（从服务端更新配置）。任何异常都收敛成
/// [UpdateOutcome.failed]，不往外抛。
Future<UpdateCheckResult> checkForUpdate({
  http.Client? client,
  String? currentVersion,
  String? deviceKey,
  String? packageName,
}) async {
  final local = currentVersion ?? await readCurrentVersion();
  if (local.isEmpty) {
    return const UpdateCheckResult(outcome: UpdateOutcome.failed);
  }
  final key = deviceKey ?? (await collectDeviceIdentity()).key;
  final pkg = packageName ?? await readPackageName();
  final params = <String>[
    if (key.isNotEmpty) 'deviceKey=${Uri.encodeQueryComponent(key)}',
    if (pkg.isNotEmpty) 'pkg=${Uri.encodeQueryComponent(pkg)}',
  ];
  final query = params.isEmpty ? '' : '?${params.join('&')}';
  final owned = client == null;
  final agent = client ?? http.Client();
  try {
    final response = await agent
        .get(
          Uri.parse('$kUpdateConfigApi$query'),
          headers: <String, String>{
            'Accept': 'application/json',
            'User-Agent': 'Yigui/$local',
          },
        )
        .timeout(kUpdateCheckTimeout);
    if (response.statusCode != 200) {
      return UpdateCheckResult(
        outcome: UpdateOutcome.failed,
        currentVersion: local,
      );
    }
    return resultFromUpdateConfig(
      jsonDecode(utf8.decode(response.bodyBytes)),
      local,
    );
  } catch (_) {
    return UpdateCheckResult(
      outcome: UpdateOutcome.failed,
      currentVersion: local,
    );
  } finally {
    if (owned) agent.close();
  }
}
