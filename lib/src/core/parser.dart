import 'bili_api.dart';
import 'bili_url.dart';
import 'dash_builder.dart';
import 'log_store.dart';
import 'models.dart';

class ResolvedTarget {
  const ResolvedTarget({required this.info, required this.page});

  final VideoInfo info;
  final PlayPage page;
}

/// 解析编排：地址 -> 视频/番剧信息 -> 选中分 P -> playurl -> 可选流列表。
class ParseService {
  ParseService({required this.api, required this.settings});

  final BiliApi api;
  final AppSettings settings;

  /// 短链只在这里展开，展开后的地址必须能识别。
  Future<BiliTarget> resolveTarget(String input) async {
    var target = BiliUrl.parse(input);
    if (target.kind == TargetKind.shortLink) {
      final shortUrl = target.shortUrl;
      if (shortUrl == null) {
        throw BiliException('短链地址不完整');
      }
      final expanded = await api.expandShortLink(shortUrl);
      target = BiliUrl.parse(expanded);
      if (!target.isSupported) {
        throw BiliException('短链展开后仍无法识别：$expanded');
      }
    }
    return target;
  }

  Future<ResolvedTarget> fetchTargetInfo(
    BiliTarget target,
    String cookie, {
    int? pageOverride,
  }) async {
    final VideoInfo info;
    if (target.kind == TargetKind.video) {
      info = await api.fetchVideo(cookie, bvid: target.bvid, aid: target.aid);
    } else {
      info = await api.fetchSeason(cookie, epId: target.epId, seasonId: target.seasonId);
    }
    if (info.pages.isEmpty) {
      throw BiliException('没有可下载的分 P');
    }
    final page = _selectPage(target, info, pageOverride);
    return ResolvedTarget(info: info, page: page);
  }

  PlayPage _selectPage(BiliTarget target, VideoInfo info, int? pageOverride) {
    final epId = target.epId;
    if (epId != null && epId > 0) {
      for (final page in info.pages) {
        if (page.epId == epId) return page;
      }
    }
    final requested = pageOverride ?? target.page;
    final index = (requested - 1).clamp(0, info.pages.length - 1);
    return info.pages[index];
  }

  Future<ParsedMedia> parseTarget(
    String input, {
    required WebCookie cookie,
    required AppToken token,
    int? quality,
    int? pageOverride,
  }) async {
    final target = await resolveTarget(input);
    if (!target.isSupported) {
      throw BiliException('无法识别的地址。首版支持普通视频、番剧与课程分集地址');
    }
    final resolved = await fetchTargetInfo(target, cookie.raw, pageOverride: pageOverride);
    return buildMedia(
      target: target,
      resolved: resolved,
      cookie: cookie,
      token: token,
      quality: quality,
    );
  }

  Future<ParsedMedia> buildMedia({
    required BiliTarget target,
    required ResolvedTarget resolved,
    required WebCookie cookie,
    required AppToken token,
    int? quality,
  }) async {
    final page = resolved.page;
    final info = resolved.info;
    final aid = page.aid > 0 ? page.aid : info.aid;
    final qn = quality ?? settings.preferredQuality;
    final bangumi = target.kind == TargetKind.bangumi || target.kind == TargetKind.cheese;

    final channels = <String>[];
    if (settings.preferAppApi && !token.isEmpty) channels.add('app');
    channels.add('web');
    if (!channels.contains('app') && !token.isEmpty) channels.add('app');

    LogStore.instance.add(
      '解析',
      '开始：${info.title.isEmpty ? page.part : info.title}'
      '｜aid=$aid cid=${page.cid} qn=$qn'
      '｜APP Token ${token.isEmpty ? '无' : '有'}，优先 APP '
      '${settings.preferAppApi ? '开' : '关'}'
      '｜通道顺序 ${channels.map(_channelLabel).join(' → ')}',
    );

    BiliException? lastError;
    for (final channel in channels) {
      final label = _channelLabel(channel);
      try {
        final data = channel == 'app'
            ? await api.fetchPlayUrlApp(
                accessToken: token.accessToken,
                aid: aid,
                cid: page.cid,
                qn: qn,
              )
            : await api.fetchPlayUrlWeb(
                cookie: cookie.raw,
                bangumi: bangumi,
                aid: aid,
                cid: page.cid,
                epId: page.epId,
                qn: qn,
              );
        var videos = DashBuilder.videoStreams(data);
        var audios = DashBuilder.audioStreams(data);
        if (videos.isEmpty) {
          throw BiliException('该通道没有返回可选视频流');
        }
        // gRPC PlayView 只补 REST 拿不到的档位（129 HDR Vivid）：同 id 已有就跳过，
        // 不覆盖 REST 那份多编码列表。网页通道也补，只要手上有 APP Token。
        var usedLabel = label;
        if (settings.useAppGrpc) {
          final supplement = await _supplementFromGrpc(
            token: token,
            aid: aid,
            cid: page.cid,
            videos: videos,
            audios: audios,
          );
          videos = supplement.videos;
          audios = supplement.audios;
          if (supplement.added) usedLabel = '$label+gRPC';
        }
        final dashDuration = DashBuilder.durationOf(data);
        final best = videos.reduce(
          (left, right) => qualityRank(left.id) <= qualityRank(right.id) ? left : right,
        );
        final maxQuality = best.id;
        LogStore.instance.add(
          '解析',
          '$usedLabel 成功：视频 ${videos.length} 条（${_videoSummary(videos)}）；'
          '音频 ${audios.length} 条（${audios.map((stream) => stream.label).join('、')}）',
        );
        LogStore.instance.add(
          '解析',
          '采用 $usedLabel，最高 ${qualityLabel(maxQuality)}（$maxQuality）',
        );
        return ParsedMedia(
          info: info,
          page: page,
          videos: videos,
          audios: audios,
          durationSec: dashDuration > 0 ? dashDuration : page.durationSec,
          channel: usedLabel,
          guestLimited: qualityRank(maxQuality) > qualityRank(qn),
        );
      } on Exception catch (error) {
        lastError = error is BiliException ? error : BiliException('$error');
        LogStore.instance.add('解析', '$label 失败：$lastError');
      }
    }
    LogStore.instance.add('解析', '所有通道都失败：${lastError ?? '解析失败'}');
    throw lastError ?? BiliException('解析失败');
  }

  static String _channelLabel(String channel) => channel == 'app' ? 'APP 通道' : '网页通道';

  /// 用 APP 端 gRPC PlayView 补齐 REST 通道拿不到的档位。
  ///
  /// 失败只写日志：REST 的结果照旧可用，缺 129 不影响原有解析。
  Future<({List<MediaStream> videos, List<MediaStream> audios, bool added})>
      _supplementFromGrpc({
    required AppToken token,
    required int aid,
    required int cid,
    required List<MediaStream> videos,
    required List<MediaStream> audios,
  }) async {
    if (token.isEmpty) {
      return (videos: videos, audios: audios, added: false);
    }
    final Map<String, dynamic> data;
    try {
      data = await api.fetchPlayUrlAppGrpc(
        accessToken: token.accessToken,
        aid: aid,
        cid: cid,
      );
    } on Exception catch (error) {
      LogStore.instance.add('解析', 'gRPC 补充失败：$error，沿用 APP 通道结果');
      return (videos: videos, audios: audios, added: false);
    }
    final knownVideoIds = videos.map((stream) => stream.id).toSet();
    final knownAudioIds = audios.map((stream) => stream.id).toSet();
    final extraVideos = DashBuilder.videoStreams(data)
        .where((stream) => !knownVideoIds.contains(stream.id))
        .toList();
    final extraAudios = DashBuilder.audioStreams(data)
        .where((stream) => !knownAudioIds.contains(stream.id))
        .toList();
    if (extraVideos.isEmpty && extraAudios.isEmpty) {
      LogStore.instance.add('解析', 'gRPC 补充：该视频没有 REST 通道之外的新档位');
      return (videos: videos, audios: audios, added: false);
    }
    final mergedAudios = extraAudios.isEmpty
        ? audios
        : ([...audios, ...extraAudios]..sort((left, right) => left.id.compareTo(right.id)));
    if (extraVideos.isEmpty) {
      LogStore.instance.add('解析', 'gRPC 补充：音频 +${extraAudios.length} 条');
      return (videos: videos, audios: mergedAudios, added: true);
    }
    LogStore.instance.add(
      '解析',
      'gRPC 补充：视频 +${extraVideos.length} 条（${_videoSummary(extraVideos)}）'
      '${extraAudios.isEmpty ? '' : '；音频 +${extraAudios.length} 条'}',
    );
    return (
      videos: DashBuilder.sortVideos([...videos, ...extraVideos]),
      audios: mergedAudios,
      added: true,
    );
  }

  /// 档位列表写进日志，方便对照「到底解析到了哪些画质」。
  static String _videoSummary(List<MediaStream> videos) {
    const limit = 8;
    final head = videos
        .take(limit)
        .map((stream) => '${stream.label}#${stream.id}/${stream.codecs}')
        .join('、');
    return videos.length > limit ? '$head …' : head;
  }
}
