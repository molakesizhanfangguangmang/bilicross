// 数据模型与常量。标识符为英文，界面文案统一走 [AppLocalizations]。

import '../i18n/app_localizations.dart';
import '../i18n/app_localizations_zh.dart';
import 'splash_config.dart';

const String kDefaultAppKey = '783bbb7264451d82';
const String kDefaultAppSec = '2653583c8873dea268ab9386918b1d65';

const String kWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0';

/// APP 通道使用移动端 UA。桌面串 [kWebUserAgent] 仅留作自定义 UA 的参考，不再是默认值。
const String kAppUserAgent = 'Mozilla/5.0 BiliDroid/1.0.0 (bbcallen@gmail.com)';

/// 兜底 UA。B 站 CDN 对空 UA 直接 403，桌面长串又会被移动端（platform=android）
/// 地址拒绝，实测两类地址都能过的只有这种短串。
const String kFallbackUserAgent = 'Mozilla/5.0';

/// 网页地址下载必须带这个 Referer；移动端地址带了会被 CDN 403。
const String kSiteReferer = 'https://www.bilibili.com/';

/// 桌面浏览器 UA：扫码登录接口与内置网页登录页都用它。
/// 这两处要的是 PC 站行为（二维码取码、登录页展示），
/// 移动端 UA 会被 passport 按 H5 处理，走不到同一套网页 Cookie。
/// 注意：下载与 APP API 不用它，那两条路各有自己的 UA（见 kAppUserAgent / kFallbackUserAgent）。
const String kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// UA 配置留空时回落到 [kFallbackUserAgent]。
String effectiveUserAgent(String raw) {
  final value = raw.trim();
  return value.isEmpty ? kFallbackUserAgent : value;
}

/// playurl 的 fnval 位：16 DASH + 64 HDR + 128 4K + 256 杜比音频 + 512 杜比视界
/// + 1024 8K + 2048 AV1。UGC 端点用这一组。
const int kFnvalDash = 4048;

/// 番剧/课程走 /pgc/、/pugv/ 端点，额外接受 8192（智能修复）。
/// UGC 端点带上这位会直接 -400，所以两边必须分开。
const int kFnvalDashPgc = 4048 | 8192;

/// APP 端点再加 16384（HDR Vivid）。该位只有 APP 接口认，且需要大会员；
/// 网页端点带上会被拒，故只加在 APP 通道。
const int kFnvalDashApp = 4048 | 16384;

/// 视频清晰度编号 -> 展示名。仅列首版会遇到的档位，其余回落到编号本身。
const Map<int, String> kQualityNames = {
  6: '240P',
  16: '360P',
  32: '480P',
  64: '720P',
  74: '720P60',
  80: '1080P',
  100: '智能修复',
  112: '1080P+',
  116: '1080P60',
  117: '1080P60+',
  120: '4K',
  125: 'HDR',
  126: '杜比视界',
  127: '8K',
  129: 'HDR Vivid',
};

/// 展示顺序，从高到低。不能按编号排：HDR Vivid 的编号（129）比 8K（127）大，
/// 档位却在 8K 之下。这张表同时决定「最高」判定、列表顺序与默认勾选行。
/// 顺序由用户 2026-09-17 定：8K → HDR Vivid → 杜比视界 → HDR → 4K。
const List<int> kQualityRank = [
  127, 129, 126, 125, 120, 117, 116, 112, 100, 80, 74, 64, 48, 32, 16, 6, 5,
];

/// 越小越高。未登记的档位排在所有已登记档位之后，彼此再按编号从大到小。
int qualityRank(int id) {
  final index = kQualityRank.indexOf(id);
  if (index >= 0) return index;
  return kQualityRank.length + (0x7fffffff - (id & 0x7fffffff));
}

/// 音频编号 -> 展示名。
const Map<int, String> kAudioNames = {
  30216: '64K',
  30232: '132K',
  30280: '192K',
  30250: '杜比全景声',
  30251: 'Hi-Res 无损',
};

/// 编号 -> 需要翻译的文案 key。其余档位名（1080P、HDR Vivid 之类）中英同名，
/// 直接沿用 [kQualityNames] / [kAudioNames]。
const Map<int, String> kVideoQualityKeys = {100: 'quality.100', 126: 'quality.126'};
const Map<int, String> kAudioQualityKeys = {
  30250: 'quality.30250',
  30251: 'quality.30251',
};

/// 语言代码只接受三个值，其它一律回落到简体中文：旧配置没有这个字段、
/// 或存了不认识的值，都不能让界面变成没翻译的状态。
String normalizeLocaleCode(String? raw) => switch (raw) {
      kLocaleSystem || kLocaleZhCN || kLocaleEnUS => raw!,
      _ => kLocaleZhCN,
    };

/// 档位展示名。`l10n` 为空时给中文，老调用点不用改也不会编译失败。
String qualityLabel(int id, [AppLocalizations? l10n]) {
  final t = l10n ?? const AppLocalizationsZh();
  final key = kVideoQualityKeys[id];
  if (key != null) return t.tr(key);
  final raw = kQualityNames[id];
  if (raw != null) return raw;
  return t.tr('quality.fallbackVideo', {'id': '$id'});
}

String audioLabel(int id, [AppLocalizations? l10n]) {
  final t = l10n ?? const AppLocalizationsZh();
  final key = kAudioQualityKeys[id];
  if (key != null) return t.tr(key);
  final raw = kAudioNames[id];
  if (raw != null) return raw;
  return t.tr('quality.fallbackAudio', {'id': '$id'});
}

/// 按任务记录的档位号与编码挑流。同档位多编码时优先编码一致的那条，否则取该档位第一条。
/// 返回 null 表示这次解析结果里没有这个档位，调用方据此报错，不要静默换成别的档位。
MediaStream? pickStream(List<MediaStream> streams, int qualityId, String codecs) {
  if (qualityId <= 0) return null;
  final sameId = streams.where((item) => item.id == qualityId).toList();
  if (sameId.isEmpty) return null;
  if (codecs.isNotEmpty) {
    for (final item in sameId) {
      if (item.codecs == codecs) return item;
    }
  }
  return sameId.first;
}

/// 重试或重新解析时按任务记录挑流。`recorded` 是记录的档位号：
/// 0 表示这条轨道不下载，-1 表示老任务没记录（取 [fallbackFirst] 指定的那一端，
/// 视频取第一条、音频取最后一条），其余按档位号取。
/// 返回 null 表示这次解析结果里没有可用的流，调用方据此决定报错还是降级。
MediaStream? resolveRecordedStream(
  List<MediaStream> streams,
  int recorded,
  String codecs, {
  required bool fallbackFirst,
}) {
  if (recorded == 0) return null;
  if (recorded < 0) {
    if (streams.isEmpty) return null;
    return fallbackFirst ? streams.first : streams.last;
  }
  return pickStream(streams, recorded, codecs);
}

/// 编解码器短名，用于在同清晰度多编码之间区分。
String codecShortName(String codecs) {
  final lower = codecs.toLowerCase();
  if (lower.startsWith('avc')) return 'AVC';
  if (lower.startsWith('hev') || lower.startsWith('hvc')) return 'HEVC';
  if (lower.startsWith('av01') || lower.startsWith('av1')) return 'AV1';
  if (lower.startsWith('ec-3') || lower.startsWith('eac3')) return 'E-AC-3';
  if (lower.startsWith('flac')) return 'FLAC';
  if (lower.startsWith('mp4a')) return 'AAC';
  return codecs;
}

/// 地址识别结果。
enum TargetKind { video, bangumi, cheese, shortLink, unknown }

class BiliTarget {
  const BiliTarget({
    required this.kind,
    this.bvid,
    this.aid,
    this.epId,
    this.seasonId,
    this.page = 1,
    this.shortUrl,
    required this.source,
  });

  final TargetKind kind;
  final String? bvid;
  final int? aid;
  final int? epId;
  final int? seasonId;

  /// 分 P 序号，从 1 开始。
  final int page;
  final String? shortUrl;
  final String source;

  bool get isSupported =>
      kind == TargetKind.video || kind == TargetKind.bangumi || kind == TargetKind.cheese;

  String get displayId {
    if (bvid != null) return page > 1 ? '$bvid P$page' : bvid!;
    if (aid != null) return page > 1 ? 'av$aid P$page' : 'av$aid';
    if (epId != null) return 'ep$epId';
    if (seasonId != null) return 'ss$seasonId';
    return source;
  }
}

class PlayPage {
  const PlayPage({
    required this.page,
    required this.cid,
    required this.part,
    required this.durationSec,
    this.aid = 0,
    this.epId = 0,
  });

  final int page;
  final int cid;
  final String part;
  final int durationSec;

  /// 番剧分集自带 aid；普通视频沿用所属视频的 aid。
  final int aid;
  final int epId;

  Map<String, dynamic> toJson() => {
        'page': page,
        'cid': cid,
        'part': part,
        'duration': durationSec,
        'aid': aid,
        'ep_id': epId,
      };

  static PlayPage fromJson(Map<String, dynamic> json) => PlayPage(
        page: (json['page'] as num?)?.toInt() ?? 1,
        cid: (json['cid'] as num?)?.toInt() ?? 0,
        part: json['part'] as String? ?? '',
        durationSec: (json['duration'] as num?)?.toInt() ?? 0,
        aid: (json['aid'] as num?)?.toInt() ?? 0,
        epId: (json['ep_id'] as num?)?.toInt() ?? 0,
      );
}

class VideoInfo {
  const VideoInfo({
    required this.bvid,
    required this.aid,
    required this.title,
    required this.owner,
    required this.cover,
    required this.durationSec,
    required this.pages,
  });

  final String bvid;
  final int aid;
  final String title;
  final String owner;
  final String cover;
  final int durationSec;
  final List<PlayPage> pages;
}

class MediaStream {
  const MediaStream({
    required this.id,
    required this.label,
    required this.codecs,
    required this.bandwidth,
    required this.url,
    this.backupUrls = const [],
    this.width = 0,
    this.height = 0,
    this.sizeBytes = 0,
  });

  final int id;
  final String label;
  final String codecs;
  final int bandwidth;
  final String url;
  final List<String> backupUrls;
  final int width;
  final int height;
  final int sizeBytes;

  bool get isVideo => height > 0;

  String get detail {
    if (isVideo) {
      final size = sizeBytes > 0 ? ' · ${formatBytes(sizeBytes)}' : '';
      return '${width}x$height · ${codecShortName(codecs)} · ${formatBitrate(bandwidth)}$size';
    }
    return '${codecShortName(codecs)} · ${formatBitrate(bandwidth)}';
  }
}

class ParsedMedia {
  const ParsedMedia({
    required this.info,
    required this.page,
    required this.videos,
    required this.audios,
    required this.durationSec,
    required this.channel,
    required this.guestLimited,
  });

  final VideoInfo info;
  final PlayPage page;
  final List<MediaStream> videos;
  final List<MediaStream> audios;
  final int durationSec;

  /// 实际命中的解析通道，写入任务记录。
  final String channel;

  /// 无 Cookie 或无有效 Token 时，高清晰度会被限制，界面需要提示。
  final bool guestLimited;

  MediaStream? get bestVideo => videos.isEmpty ? null : videos.first;

  MediaStream? get bestAudio => audios.isEmpty ? null : audios.last;

  ParsedMedia copyWith({List<MediaStream>? videos, List<MediaStream>? audios}) => ParsedMedia(
        info: info,
        page: page,
        videos: videos ?? this.videos,
        audios: audios ?? this.audios,
        durationSec: durationSec,
        channel: channel,
        guestLimited: guestLimited,
      );
}

class WebCookie {
  const WebCookie({
    required this.raw,
    required this.sessData,
    required this.biliJct,
    required this.dedeUserId,
  });

  const WebCookie.empty()
      : raw = '',
        sessData = '',
        biliJct = '',
        dedeUserId = '';

  final String raw;
  final String sessData;
  final String biliJct;
  final String dedeUserId;

  bool get isEmpty => raw.isEmpty;

  bool get isComplete =>
      sessData.isNotEmpty && biliJct.isNotEmpty && dedeUserId.isNotEmpty;

  /// 界面只展示字段是否齐全与掩码，不展示完整值。
  String get maskedSessData => maskSecret(sessData);

  Map<String, dynamic> toJson() => {
        'raw': raw,
        'sessdata': sessData,
        'bili_jct': biliJct,
        'dede_user_id': dedeUserId,
      };

  static WebCookie fromJson(Map<String, dynamic> json) => WebCookie(
        raw: json['raw'] as String? ?? '',
        sessData: json['sessdata'] as String? ?? '',
        biliJct: json['bili_jct'] as String? ?? '',
        dedeUserId: json['dede_user_id'] as String? ?? '',
      );
}

class AppToken {
  const AppToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.mid,
    required this.obtainedAtMs,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final int mid;
  final int obtainedAtMs;

  bool get isEmpty => accessToken.isEmpty;

  int get expiresAtMs => obtainedAtMs + expiresIn * 1000;

  String get masked => maskSecret(accessToken);

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_in': expiresIn,
        'mid': mid,
        'obtained_at_ms': obtainedAtMs,
      };

  static AppToken fromJson(Map<String, dynamic> json) => AppToken(
        accessToken: json['access_token'] as String? ?? '',
        refreshToken: json['refresh_token'] as String? ?? '',
        expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
        mid: (json['mid'] as num?)?.toInt() ?? 0,
        obtainedAtMs: (json['obtained_at_ms'] as num?)?.toInt() ?? 0,
      );
}

class AccountState {
  const AccountState({
    required this.loggedIn,
    this.uname = '',
    this.mid = 0,
    this.vipStatus = 0,
    this.vipType = 0,
    this.coins = 0,
    this.message = '',
  });

  const AccountState.unknown() : this(loggedIn: false, message: '未检测');

  final bool loggedIn;
  final String uname;
  final int mid;
  final int vipStatus;
  final int vipType;
  final double coins;
  final String message;

  /// 会员状态。`l10n` 为空时给中文，测试与非 UI 调用点可以直接用。
  String vipLabel([AppLocalizations? l10n]) {
    final t = l10n ?? const AppLocalizationsZh();
    if (vipStatus != 1) return t.tr('vip.none');
    return switch (vipType) {
      2 => t.tr('vip.annual'),
      1 => t.tr('vip.monthly'),
      _ => t.tr('vip.general'),
    };
  }
}

enum TaskStage { pending, resolving, downloading, muxing, paused, stopped, done, failed }

extension TaskStageLabel on TaskStage {
  /// 阶段名。`l10n` 为空时给中文，日志与非 UI 调用点可以直接用。
  String label([AppLocalizations? l10n]) {
    final t = l10n ?? const AppLocalizationsZh();
    return switch (this) {
      TaskStage.pending => t.tr('stage.pending'),
      TaskStage.resolving => t.tr('stage.resolving'),
      TaskStage.downloading => t.tr('stage.downloading'),
      TaskStage.muxing => t.tr('stage.muxing'),
      TaskStage.paused => t.tr('stage.paused'),
      TaskStage.stopped => t.tr('stage.stopped'),
      TaskStage.done => t.tr('stage.done'),
      TaskStage.failed => t.tr('stage.failed'),
    };
  }
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.source,
    required this.infoId,
    required this.page,
    required this.cid,
    required this.outputPath,
    required this.engine,
    required this.channel,
    this.stage = TaskStage.pending,
    this.message = '',
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.videoUrl = '',
    this.audioUrl = '',
    this.videoBackups = const [],
    this.audioBackups = const [],
    this.videoPath = '',
    this.audioPath = '',
    this.videoQualityId = 0,
    this.audioQualityId = 0,
    this.videoCodecs = '',
    this.audioCodecs = '',
    this.merged = false,
    this.createdAtMs = 0,
  });

  final String id;
  String title;
  final String source;
  final String infoId;
  final int page;
  final int cid;
  String outputPath;
  String engine;
  String channel;
  TaskStage stage;
  String message;
  int totalBytes;
  int receivedBytes;
  String videoUrl;
  String audioUrl;
  List<String> videoBackups;
  List<String> audioBackups;
  String videoPath;
  String audioPath;

  /// 用户选的档位号：0 表示这条轨道不下载，-1 表示旧任务没有记录（按默认取流）。
  /// 重试与重新解析都按这里的档位取流，不再改成「列表第一条」。
  int videoQualityId;
  int audioQualityId;

  /// 同档位多编码时用来还原到同一个编码。
  String videoCodecs;
  String audioCodecs;
  bool merged;
  final int createdAtMs;

  double get progress {
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  /// 只选了一条轨道的任务：产物就是那条流本身，没有可合并的分片，
  /// 「重试合并」与「清理残留」都不该出现。
  bool get singleTrack => videoQualityId == 0 || audioQualityId == 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'source': source,
        'info_id': infoId,
        'page': page,
        'cid': cid,
        'output_path': outputPath,
        'engine': engine,
        'channel': channel,
        'stage': stage.name,
        'message': message,
        'total_bytes': totalBytes,
        'received_bytes': receivedBytes,
        'video_url': videoUrl,
        'audio_url': audioUrl,
        'video_backups': videoBackups,
        'audio_backups': audioBackups,
        'video_path': videoPath,
        'audio_path': audioPath,
        'video_quality_id': videoQualityId,
        'audio_quality_id': audioQualityId,
        'video_codecs': videoCodecs,
        'audio_codecs': audioCodecs,
        'merged': merged,
        'created_at_ms': createdAtMs,
      };

  static DownloadTask fromJson(Map<String, dynamic> json) => DownloadTask(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        source: json['source'] as String? ?? '',
        infoId: json['info_id'] as String? ?? '',
        page: (json['page'] as num?)?.toInt() ?? 1,
        cid: (json['cid'] as num?)?.toInt() ?? 0,
        outputPath: json['output_path'] as String? ?? '',
        engine: json['engine'] as String? ?? 'dart',
        channel: json['channel'] as String? ?? '',
        stage: TaskStage.values.firstWhere(
          (value) => value.name == json['stage'],
          orElse: () => TaskStage.pending,
        ),
        message: json['message'] as String? ?? '',
        totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
        receivedBytes: (json['received_bytes'] as num?)?.toInt() ?? 0,
        videoUrl: json['video_url'] as String? ?? '',
        audioUrl: json['audio_url'] as String? ?? '',
        videoBackups: (json['video_backups'] as List?)?.cast<String>() ?? const [],
        audioBackups: (json['audio_backups'] as List?)?.cast<String>() ?? const [],
        videoPath: json['video_path'] as String? ?? '',
        audioPath: json['audio_path'] as String? ?? '',
        videoQualityId: (json['video_quality_id'] as num?)?.toInt() ?? -1,
        audioQualityId: (json['audio_quality_id'] as num?)?.toInt() ?? -1,
        videoCodecs: json['video_codecs'] as String? ?? '',
        audioCodecs: json['audio_codecs'] as String? ?? '',
        merged: json['merged'] as bool? ?? false,
        createdAtMs: (json['created_at_ms'] as num?)?.toInt() ?? 0,
      );
}

class AppSettings {
  AppSettings({
    this.downloadDir = '',
    this.preferredQuality = 80,
    this.preferredAudio = 30280,
    this.engine = 'dart',
    this.ffmpegPath = '',
    this.proxy = '',
    this.appKey = kDefaultAppKey,
    this.appSec = kDefaultAppSec,
    this.userAgent = '',
    this.maxParallelTasks = 2,
    this.autoMux = true,
    this.preferAppApi = false,
    this.useAppGrpc = true,
    this.partsPerFile = 4,
    this.preferFfmpegMux = true,
    this.localeCode = kLocaleZhCN,
    this.closeToTray = true,
    this.splashEnabled = false,
    this.splashSeconds = 2.0,
  });

  String downloadDir;
  int preferredQuality;
  int preferredAudio;
  String engine;
  String ffmpegPath;
  String proxy;
  String appKey;
  String appSec;
  String userAgent;
  int maxParallelTasks;
  bool autoMux;
  bool preferAppApi;

  /// APP 通道解析成功后再补一次 gRPC PlayView，取 REST 端点不给的
  /// HDR Vivid（qn=129）档位；失败只写日志，不影响原有结果。
  bool useAppGrpc;

  /// 单文件并发连接数（1 表示单连接）。
  int partsPerFile;

  /// 合并时是否优先使用已找到的 ffmpeg。
  bool preferFfmpegMux;

  /// 界面语言：'system' 跟随系统，'zh-CN'，'en-US'。
  /// 默认与旧配置缺失时都是 'zh-CN'，新装和升级上来都从简体中文开始。
  String localeCode;

  /// 关闭主窗口的行为：true 最小化到系统托盘（下载继续跑），false 直接退出。
  /// 只对 Windows 生效；其它平台读不到也不使用。
  bool closeToTray;

  /// 启动时是否显示自定义开屏。默认关，用户自己开了才有。
  bool splashEnabled;

  /// 开屏停留秒数，0 表示不停留（只闪一下过渡）。上限见 [kSplashMaxSeconds]。
  double splashSeconds;

  Map<String, dynamic> toJson() => {
        'download_dir': downloadDir,
        'preferred_quality': preferredQuality,
        'preferred_audio': preferredAudio,
        'engine': engine,
        'ffmpeg_path': ffmpegPath,
        'proxy': proxy,
        'app_key': appKey,
        'app_sec': appSec,
        'user_agent': userAgent,
        'max_parallel_tasks': maxParallelTasks,
        'auto_mux': autoMux,
        'prefer_app_api': preferAppApi,
        'use_app_grpc': useAppGrpc,
        'parts_per_file': partsPerFile,
        'prefer_ffmpeg_mux': preferFfmpegMux,
        'locale_code': localeCode,
        'close_to_tray': closeToTray,
        'splash_enabled': splashEnabled,
        'splash_seconds': splashSeconds,
      };

  static AppSettings fromJson(Map<String, dynamic> json) => AppSettings(
        downloadDir: json['download_dir'] as String? ?? '',
        preferredQuality: (json['preferred_quality'] as num?)?.toInt() ?? 80,
        preferredAudio: (json['preferred_audio'] as num?)?.toInt() ?? 30280,
        engine: json['engine'] as String? ?? 'dart',
        ffmpegPath: json['ffmpeg_path'] as String? ?? '',
        proxy: json['proxy'] as String? ?? '',
        appKey: json['app_key'] as String? ?? kDefaultAppKey,
        appSec: json['app_sec'] as String? ?? kDefaultAppSec,
        userAgent: json['user_agent'] as String? ?? '',
        maxParallelTasks: (json['max_parallel_tasks'] as num?)?.toInt() ?? 2,
        autoMux: json['auto_mux'] as bool? ?? true,
        preferAppApi: json['prefer_app_api'] as bool? ?? false,
        useAppGrpc: json['use_app_grpc'] as bool? ?? true,
        partsPerFile: (json['parts_per_file'] as num?)?.toInt() ?? 4,
        preferFfmpegMux: json['prefer_ffmpeg_mux'] as bool? ?? true,
        localeCode: normalizeLocaleCode(json['locale_code'] as String?),
        closeToTray: json['close_to_tray'] as bool? ?? true,
        splashEnabled: json['splash_enabled'] as bool? ?? false,
        splashSeconds: clampSplashSeconds(
          (json['splash_seconds'] as num?)?.toDouble() ?? 2.0,
        ),
      );
}

/// 掩码工具：只保留前 4 位与后 2 位，短凭据整体打码。
String maskSecret(String value) {
  if (value.isEmpty) return '';
  if (value.length <= 8) return '******';
  return '${value.substring(0, 4)}******${value.substring(value.length - 2)}';
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatBitrate(int bitsPerSecond, [AppLocalizations? l10n]) {
  if (bitsPerSecond <= 0) {
    return (l10n ?? const AppLocalizationsZh()).tr('quality.unknownBitrate');
  }
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
  }
  return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
}

String formatDuration(int seconds) {
  if (seconds <= 0) return '--:--';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 去掉文件名里不能用于 Windows 与 Android 的字符。凭据不参与命名。
String sanitizeFileName(String name) {
  var value = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.isEmpty) value = 'video';
  if (value.length > 80) value = value.substring(0, 80).trim();
  return value;
}
