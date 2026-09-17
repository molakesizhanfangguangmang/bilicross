import 'models.dart';

/// B 站地址识别。只做本地字符串判断，短链需要联网展开时返回 [TargetKind.shortLink]。
class BiliUrl {
  const BiliUrl._();

  static final RegExp _bvid = RegExp(r'\bBV[0-9A-Za-z]{10}\b');
  static final RegExp _av = RegExp(r'\bav(\d+)\b', caseSensitive: false);
  static final RegExp _ep = RegExp(r'\bep(\d+)\b', caseSensitive: false);
  static final RegExp _ss = RegExp(r'\bss(\d+)\b', caseSensitive: false);
  static final RegExp _page = RegExp(r'[?&]p=(\d+)');

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
