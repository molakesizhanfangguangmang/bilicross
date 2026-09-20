import 'package:bilicross/src/core/bili_url.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('空间 lists 链接', () {
    test('当合集入口，并留下 URL 里的 mid', () {
      final target = BiliUrl.parse(
        'https://space.bilibili.com/11231484/lists/3144260?type=season',
      );
      expect(target.kind, TargetKind.ugcSeason);
      expect(target.seasonId, 3144260);
      // mid 必须留下来：翻页接口要它，丢了就得去反查，
      // 而 B 站没有公开的 season→mid 端点。
      expect(target.mid, 11231484);
    });

    test('不带 ?type=season 也认', () {
      final target = BiliUrl.parse(
        'https://space.bilibili.com/11231484/lists/3144260',
      );
      expect(target.kind, TargetKind.ugcSeason);
      expect(target.seasonId, 3144260);
      expect(target.mid, 11231484);
    });
  });

  group('UP 空间链接', () {
    test('空间主页当空间入口，带上 mid', () {
      final target = BiliUrl.parse('https://space.bilibili.com/11231484');
      expect(target.kind, TargetKind.space);
      expect(target.mid, 11231484);
      // 空间不是可直接解析的媒体目标，要弹窗让用户挑。
      expect(target.isSupported, isFalse);
    });

    test('带尾斜杠与查询串也认', () {
      final target = BiliUrl.parse(
        'https://space.bilibili.com/11231484/?spm_id_from=333.999',
      );
      expect(target.kind, TargetKind.space);
      expect(target.mid, 11231484);
    });

    test('lists 链接优先当合集，不会被空间主页那条更宽的模式抢走', () {
      final target = BiliUrl.parse(
        'https://space.bilibili.com/11231484/lists/3144260?type=season',
      );
      expect(target.kind, TargetKind.ugcSeason);
      expect(target.seasonId, 3144260);
      expect(target.mid, 11231484);
    });
  });

  group('裸 season 编号', () {
    test('认作合集入口，但没有 mid（要靠反查，本机没有公开端点）', () {
      final target = BiliUrl.parse('season3144260');
      expect(target.kind, TargetKind.ugcSeason);
      expect(target.seasonId, 3144260);
      expect(target.mid, isNull);
    });
  });

  group('视频链接', () {
    test('BV 号带分 P', () {
      final target = BiliUrl.parse(
        'https://www.bilibili.com/video/BV1Cz421h7Na?p=3',
      );
      expect(target.kind, TargetKind.video);
      expect(target.bvid, 'BV1Cz421h7Na');
      expect(target.page, 3);
    });

    test('av 号', () {
      final target = BiliUrl.parse('https://www.bilibili.com/video/av123456');
      expect(target.kind, TargetKind.video);
      expect(target.aid, 123456);
    });

    test('b23 短链要联网展开', () {
      final target = BiliUrl.parse('https://b23.tv/hLWb54h');
      expect(target.kind, TargetKind.shortLink);
      expect(target.shortUrl, 'https://b23.tv/hLWb54h');
    });
  });

  group('番剧与课程', () {
    test('番剧 ep 带 ss', () {
      final target = BiliUrl.parse(
        'https://www.bilibili.com/bangumi/play/ep123456?ss654321',
      );
      expect(target.kind, TargetKind.bangumi);
      expect(target.epId, 123456);
      expect(target.seasonId, 654321);
    });

    test('课程 ep', () {
      final target = BiliUrl.parse(
        'https://www.bilibili.com/cheese/play/ep7654321',
      );
      expect(target.kind, TargetKind.cheese);
      expect(target.epId, 7654321);
    });
  });

  group('认不出来', () {
    test('空串与无关文本都归 unknown', () {
      expect(BiliUrl.parse('').kind, TargetKind.unknown);
      expect(BiliUrl.parse('随便一段话').kind, TargetKind.unknown);
      expect(BiliUrl.parse('随便一段话').isSupported, isFalse);
    });
  });
}
