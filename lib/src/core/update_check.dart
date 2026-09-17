import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// 项目主页：关于弹窗的「项目地址」与更新跳转都用它。
const String kProjectUrl = 'https://github.com/molakesizhanfangguangmang/bilicross';

/// 没有可用直链时的兜底地址（Release 列表页）。
const String kReleaseListUrl = '$kProjectUrl/releases';

/// GitHub 的「最新正式版」接口，预发布版不会出现在这里。
const String kLatestReleaseApi =
    'https://api.github.com/repos/molakesizhanfangguangmang/bilicross/releases/latest';

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
  });

  final UpdateOutcome outcome;

  /// 本机安装包的版本号，例如 `1.0.1`。
  final String currentVersion;

  /// 远端 Release 的 tag，例如 `v1.0.2`。
  final String latestVersion;

  final String releaseUrl;

  /// 展示用的远端版本号，保证带 `v` 前缀。
  String get latestLabel {
    if (latestVersion.isEmpty) return latestVersion;
    final first = latestVersion[0];
    if (first == 'v' || first == 'V') return latestVersion;
    return 'v$latestVersion';
  }
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
    );
  }
  return UpdateCheckResult(
    outcome: UpdateOutcome.upToDate,
    currentVersion: currentVersion,
    latestVersion: latest,
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

/// 查一次最新正式版。任何异常都收敛成 [UpdateOutcome.failed]，不往外抛。
Future<UpdateCheckResult> checkForUpdate({
  http.Client? client,
  String? currentVersion,
}) async {
  final local = currentVersion ?? await readCurrentVersion();
  if (local.isEmpty) {
    return const UpdateCheckResult(outcome: UpdateOutcome.failed);
  }
  final owned = client == null;
  final agent = client ?? http.Client();
  try {
    final response = await agent
        .get(
          Uri.parse(kLatestReleaseApi),
          headers: <String, String>{
            'Accept': 'application/vnd.github+json',
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
    return resultFromRelease(
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
