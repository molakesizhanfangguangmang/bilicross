import 'bili_api.dart';
import 'bili_url.dart';
import 'dash_builder.dart';
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

    BiliException? lastError;
    for (final channel in channels) {
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
        final videos = DashBuilder.videoStreams(data);
        final audios = DashBuilder.audioStreams(data);
        if (videos.isEmpty) {
          throw BiliException('该通道没有返回可选视频流');
        }
        final dashDuration = DashBuilder.durationOf(data);
        final maxQuality = videos.map((stream) => stream.id).reduce((a, b) => a > b ? a : b);
        return ParsedMedia(
          info: info,
          page: page,
          videos: videos,
          audios: audios,
          durationSec: dashDuration > 0 ? dashDuration : page.durationSec,
          channel: channel == 'app' ? 'APP 通道' : '网页通道',
          guestLimited: maxQuality < qn,
        );
      } on Exception catch (error) {
        lastError = error is BiliException ? error : BiliException('$error');
      }
    }
    throw lastError ?? BiliException('解析失败');
  }
}
