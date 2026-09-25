import 'dart:convert';

import 'package:http/http.dart' as http;

/// 公告后端地址。可用 `--dart-define=BILICROSS_ANNOUNCE_BASE=...` 覆盖；
/// 置空串等于停用公告（拉取直接返回失败，界面静默）。
const String kAnnouncementsBaseUrl = String.fromEnvironment(
  'BILICROSS_ANNOUNCE_BASE',
  defaultValue: 'https://bili.culture-see.de5.net',
);

/// 公告请求超时。与更新检查同一个量级：拉不到就下次再来，不拖住启动。
const Duration kAnnouncementTimeout = Duration(seconds: 8);

/// 关闭方式，由服务端逐条下发。
///
/// - [kDismissForever]：关掉就不再弹（已读落盘）；
/// - [kDismissSession]：关掉后本次运行不再弹，重启还会弹；
/// - [kDismissOnAction]：同 forever —— 点过按钮（含投票）就算处理完了。
const String kDismissForever = 'forever';
const String kDismissSession = 'session';
const String kDismissOnAction = 'onAction';

/// 投票的一个选项。
class AnnouncementOption {
  const AnnouncementOption({required this.id, required this.label});

  final String id;
  final String label;

  static AnnouncementOption? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final label = '${raw['label'] ?? ''}'.trim();
    return AnnouncementOption(id: id, label: label.isEmpty ? id : label);
  }
}

/// 跟在公告后面下发的投票。
class AnnouncementPoll {
  const AnnouncementPoll({
    required this.id,
    required this.question,
    required this.multi,
    required this.open,
    required this.options,
  });

  final String id;
  final String question;

  /// 多选。单选时服务端按「一机一票」记，客户端也不提供改票入口。
  final bool multi;

  /// 服务端按 `startsAt` / `endsAt` 算好的开关；已结束的投票不弹。
  final bool open;

  final List<AnnouncementOption> options;

  static AnnouncementPoll? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final options = <AnnouncementOption>[];
    final list = raw['options'];
    if (list is List) {
      for (final item in list) {
        final option = AnnouncementOption.fromJson(item);
        if (option != null) options.add(option);
      }
    }
    // 没有可选项的投票渲染不出来，当作没有投票。
    if (options.isEmpty) return null;
    return AnnouncementPoll(
      id: id,
      question: '${raw['question'] ?? ''}'.trim(),
      multi: raw['multi'] == true,
      // 服务端会注入 `open`；字段缺失时按「开着」处理（老数据）。
      open: raw['open'] != false,
      options: options,
    );
  }
}

/// 一条公告。
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.closable,
    required this.dismissMode,
    required this.actionLabel,
    required this.platforms,
    required this.minVersion,
    required this.maxVersion,
    required this.startsAt,
    required this.expiresAt,
    this.poll,
  });

  final String id;
  final String title;
  final String body;

  /// false = 更新性公告：弹窗不给关闭按钮，只有「立即更新」一条路。
  final bool closable;

  final String dismissMode;

  /// 按钮文案，由服务端给（「知道了」「去投票」…）；空串用界面默认值。
  final String actionLabel;

  final List<String> platforms;
  final String minVersion;
  final String maxVersion;
  final int? startsAt;
  final int? expiresAt;
  final AnnouncementPoll? poll;

  /// 不可关闭的那一类。
  bool get forced => !closable;

  /// 关掉后本次运行不再弹（重启还会弹）。
  bool get sessionOnly => dismissMode == kDismissSession;

  static Announcement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final action = raw['action'];
    final platforms = <String>[];
    final rawPlatforms = raw['platforms'];
    if (rawPlatforms is List) {
      for (final item in rawPlatforms) {
        final text = '${item ?? ''}'.trim();
        if (text.isNotEmpty) platforms.add(text);
      }
    }
    return Announcement(
      id: id,
      title: '${raw['title'] ?? ''}'.trim(),
      body: '${raw['body'] ?? ''}'.trim(),
      // 字段缺失按「可关闭」处理：不能因为少写一个字段就把用户锁死在弹窗里。
      closable: raw['closable'] != false,
      dismissMode: '${raw['dismissMode'] ?? kDismissForever}'.trim(),
      actionLabel: action is Map ? '${action['label'] ?? ''}'.trim() : '',
      platforms: platforms,
      minVersion: '${raw['minVersion'] ?? ''}'.trim(),
      maxVersion: '${raw['maxVersion'] ?? ''}'.trim(),
      startsAt: _toSeconds(raw['startsAt']),
      expiresAt: _toSeconds(raw['expiresAt']),
      poll: AnnouncementPoll.fromJson(raw['poll']),
    );
  }

  /// 本机现在该不该看到这条。
  ///
  /// ⚠️ 服务端已经按平台 / 版本 / 时间过滤过一遍，这里**再判一次**是为了本地那份
  /// 缓存：应用升级之后（或公告过期之后）断网时手里还是旧数据，不能照弹。
  bool visibleFor({
    required String version,
    required String platform,
    required DateTime now,
  }) {
    if (platforms.isNotEmpty && platform.isNotEmpty) {
      if (!platforms.contains(platform)) return false;
    }
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final start = startsAt;
    if (start != null && seconds < start) return false;
    final end = expiresAt;
    if (end != null && seconds > end) return false;
    if (version.isNotEmpty) {
      final local = versionKey(version);
      if (minVersion.isNotEmpty && compareVersionKey(local, versionKey(minVersion)) < 0) {
        return false;
      }
      if (maxVersion.isNotEmpty && compareVersionKey(local, versionKey(maxVersion)) > 0) {
        return false;
      }
    }
    return true;
  }
}

/// 一次拉取的结果。[ok] 为假表示没拉到（断网、超时、服务端异常），
/// 此时 [items] 为空 —— 调用方必须靠 [ok] 区分「拉失败」与「服务端确实没公告」，
/// 前者要退避重试，后者不能。
class AnnouncementFeed {
  const AnnouncementFeed({required this.items, required this.ok});

  const AnnouncementFeed.failed() : items = const <Announcement>[], ok = false;

  final List<Announcement> items;
  final bool ok;
}

/// 解析响应体。结构异常一律当空列表：公告不该因为一个坏字段把界面搞崩。
List<Announcement> parseAnnouncements(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const <Announcement>[];
  }
  if (decoded is! Map) return const <Announcement>[];
  final raw = decoded['announcements'];
  if (raw is! List) return const <Announcement>[];
  final out = <Announcement>[];
  for (final item in raw) {
    final announcement = Announcement.fromJson(item);
    if (announcement != null) out.add(announcement);
  }
  return out;
}

/// 版本号比较键：只取**前三段**数字（与后端的 `vkey()` 同一口径）。
///
/// ⚠️ 内测版的第四段不参与比较（`2.1.6.4` 与 `2.1.6` 同键），所以公告里的
/// `minVersion` / `maxVersion` 绝不能当「内测版比正式版新」的依据用。
List<int> versionKey(String raw) {
  final numbers = <int>[];
  for (final match in RegExp(r'\d+').allMatches(raw)) {
    numbers.add(int.parse(match.group(0)!));
    if (numbers.length == 3) break;
  }
  while (numbers.length < 3) {
    numbers.add(0);
  }
  return numbers;
}

/// 比较两个 [versionKey]：左小返回负数，右小返回正数。
int compareVersionKey(List<int> left, List<int> right) {
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i] < right[i] ? -1 : 1;
  }
  return 0;
}

/// 拉一次公告。任何异常都收敛成 [AnnouncementFeed.failed]，不往外抛。
Future<AnnouncementFeed> fetchAnnouncements({
  required String version,
  required String platform,
  http.Client? client,
  String baseUrl = kAnnouncementsBaseUrl,
  Duration timeout = kAnnouncementTimeout,
}) async {
  if (baseUrl.trim().isEmpty) return const AnnouncementFeed.failed();
  final owned = client == null;
  final agent = client ?? http.Client();
  try {
    final uri = Uri.parse('${baseUrl.trim()}/v1/announcements').replace(
      queryParameters: <String, String>{
        if (version.isNotEmpty) 'ver': version,
        if (platform.isNotEmpty) 'platform': platform,
      },
    );
    final response = await agent
        .get(uri, headers: const <String, String>{'Accept': 'application/json'})
        .timeout(timeout);
    if (response.statusCode != 200) return const AnnouncementFeed.failed();
    return AnnouncementFeed(
      items: parseAnnouncements(utf8.decode(response.bodyBytes)),
      ok: true,
    );
  } catch (_) {
    return const AnnouncementFeed.failed();
  } finally {
    if (owned) agent.close();
  }
}

/// `startsAt` / `expiresAt` 允许 ISO 字符串或秒级整数（后端两种都收）。
int? _toSeconds(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  final text = '$raw'.trim();
  if (text.isEmpty) return null;
  final direct = int.tryParse(text);
  if (direct != null) return direct;
  final parsed = DateTime.tryParse(text.replaceAll('Z', '+00:00'));
  if (parsed == null) return null;
  return parsed.toUtc().millisecondsSinceEpoch ~/ 1000;
}
