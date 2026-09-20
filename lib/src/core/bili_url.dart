import 'models.dart';

/// B 站地址识别。只做本地字符串判断，短链需要联网展开时返回 [TargetKind.shortLink]。
class BiliUrl {
  const BiliUrl._();

  static final RegExp _bvid = RegExp(r'\bBV[0-9A-Za-z]{10}\b');
  static final RegExp _av = RegExp(r'\bav(\d+)\b', caseSensitive: false);
  static final RegExp _ep = RegExp(r'\bep(\d+)\b', caseSensitive: false);
  static final RegExp _ss = RegExp(r'\bss(\d+)\b', caseSensitive: false);
  static final RegExp _page = RegExp(r'[?&]p=(\d+)');
  static final RegExp _seasonId = RegExp(r'\bseason(\d+)\b', caseSensitive: false);
  static final RegExp _spaceList = RegExp(r'space\.bilibili\.com/(\d+)/lists/(\d+)', caseSensitive: false);
  static final RegExp _spaceHome = RegExp(r'space\.bilibili\.com/(\d+)', caseSensitive: false);

  static BiliTarget parse(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      return const BiliTarget(kind: TargetKind.unknown, source: '');
    }

    final shortMatch = RegExp(r'https?://(?:www\.)?b23\.tv/([0-9A-Za-z]+)')
        .firstMatch(text);
    if (shortMatch != null && _bvid.firstMatch(text) == null) {
      return BiliTarget(
        kind: TargetKind.shortLink,
        shortUrl: shortMatch.group(0),
        source: text,
      );
    }

    final page = int.tryParse(_page.firstMatch(text)?.group(1) ?? '') ?? 1;
    final bvid = _bvid.firstMatch(text)?.group(0);

    if (text.contains('/bangumi/play/') || text.contains('/bangumi/media/')) {
      final ep = _ep.firstMatch(text)?.group(1);
      final ss = _ss.firstMatch(text)?.group(1);
      if (ep != null) {
        return BiliTarget(
          kind: TargetKind.bangumi,
          epId: int.parse(ep),
          seasonId: ss == null ? null : int.parse(ss),
          source: text,
        );
      }
      if (ss != null) {
        return BiliTarget(
          kind: TargetKind.bangumi,
          seasonId: int.parse(ss),
          source: text,
        );
      }
    }

    if (text.contains('/cheese/play/')) {
      final ep = _ep.firstMatch(text)?.group(1);
      if (ep != null) {
        return BiliTarget(
          kind: TargetKind.cheese,
          epId: int.parse(ep),
          source: text,
        );
      }
    }

    if (bvid != null) {
      return BiliTarget(
        kind: TargetKind.video,
        bvid: bvid,
        page: page,
        source: text,
      );
    }

    // 空间合集列表页（space.bilibili.com/<mid>/lists/<seasonId>）直接当合集入口。
    // mid 就在 URL 里，必须留下来 —— 翻页接口要它，丢了就只能去反查，
    // 而 B 站没有公开的 season→mid 端点。
    final spaceList = _spaceList.firstMatch(text);
    if (spaceList != null) {
      return BiliTarget(
        kind: TargetKind.ugcSeason,
        seasonId: int.parse(spaceList.group(2)!),
        mid: int.parse(spaceList.group(1)!),
        source: text,
      );
    }

    // UP 空间主页（space.bilibili.com/<mid>）：没有单集可解析，
    // 交给上层弹窗列出该 UP 的合集与系列。必须放在 lists 之后 ——
    // lists 链接同样匹配这条更宽的模式。
    final spaceHome = _spaceHome.firstMatch(text);
    if (spaceHome != null) {
      return BiliTarget(
        kind: TargetKind.space,
        mid: int.parse(spaceHome.group(1)!),
        source: text,
      );
    }

    // 裸编号 season3144260（大小写不敏感）同样当合集入口；
    // 注意要在 ss 判断之后，避免与番剧 ss 编号混淆 —— 本身的字面就是 season 前缀。
    final seasonMatch = _seasonId.firstMatch(text);
    if (seasonMatch != null) {
      return BiliTarget(
        kind: TargetKind.ugcSeason,
        seasonId: int.parse(seasonMatch.group(1)!),
        source: text,
      );
    }

    final av = _av.firstMatch(text)?.group(1);
    if (av != null) {
      return BiliTarget(
        kind: TargetKind.video,
        aid: int.parse(av),
        page: page,
        source: text,
      );
    }

    return BiliTarget(kind: TargetKind.unknown, source: text);
  }
}
