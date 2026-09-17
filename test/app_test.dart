import 'package:biliharbor/src/core/bili_url.dart';
import 'package:biliharbor/src/core/dash_builder.dart';
import 'package:biliharbor/src/core/models.dart';
import 'package:biliharbor/src/core/signing.dart';
import 'package:flutter_test/flutter_test.dart';

const String _imgKey = '7cd084941338484aae1ad9425b84077c';
const String _subKey = '4932caff0ff746eab6f01bf08b70ac45';
const String _mixinKey = 'ea1db124af3c7062474693fa704f4ff8';

Map<String, dynamic> _dashSample() => {
      'dash': {
        'duration': 212,
        'video': [
          {
            'id': 32,
            'base_url': 'https://cdn.example/v32-avc.m4s',
            'backup_url': ['https://cdn.example/b32-avc.m4s'],
            'codecs': 'avc1.64001F',
            'bandwidth': 786766,
            'width': 852,
            'height': 480,
          },
          {
            'id': 80,
            'base_url': 'https://cdn.example/v80-hevc.m4s',
            'codecs': 'hev1.1.6.L120.90',
            'bandwidth': 900000,
            'width': 1920,
            'height': 1080,
          },
          {
            'id': 80,
            'base_url': 'https://cdn.example/v80-avc.m4s',
            'codecs': 'avc1.640032',
            'bandwidth': 950000,
            'width': 1920,
            'height': 1080,
          },
        ],
        'audio': [
          {'id': 30232, 'base_url': 'https://cdn.example/a132.m4s', 'codecs': 'mp4a.40.2', 'bandwidth': 102931},
          {'id': 30280, 'base_url': 'https://cdn.example/a192.m4s', 'codecs': 'mp4a.40.2', 'bandwidth': 203786},
        ],
        'flac': {
          'audio': {'id': 30251, 'base_url': 'https://cdn.example/a-flac.m4s', 'codecs': 'flac', 'bandwidth': 1200000},
        },
      },
    };

void main() {
  group('地址识别', () {
    test('普通视频并识别分 P', () {
      final target = BiliUrl.parse('https://www.bilibili.com/video/BV1GJ411x7h7?p=3');
      expect(target.kind, TargetKind.video);
      expect(target.bvid, 'BV1GJ411x7h7');
      expect(target.page, 3);
    });

    test('av 号与裸 BV 号', () {
      expect(BiliUrl.parse('av80433022').aid, 80433022);
      expect(BiliUrl.parse('BV1GJ411x7h7').bvid, 'BV1GJ411x7h7');
    });

    test('番剧与课程', () {
      final ep = BiliUrl.parse('https://www.bilibili.com/bangumi/play/ep123456');
      expect(ep.kind, TargetKind.bangumi);
      expect(ep.epId, 123456);

      final ss = BiliUrl.parse('https://www.bilibili.com/bangumi/play/ss28747');
      expect(ss.kind, TargetKind.bangumi);
      expect(ss.seasonId, 28747);

      final cheese = BiliUrl.parse('https://www.bilibili.com/cheese/play/ep99');
      expect(cheese.kind, TargetKind.cheese);
      expect(cheese.epId, 99);
    });

    test('短链需要展开', () {
      final target = BiliUrl.parse('https://b23.tv/abcd123');
      expect(target.kind, TargetKind.shortLink);
      expect(target.shortUrl, 'https://b23.tv/abcd123');
    });

    test('无法识别的内容', () {
      expect(BiliUrl.parse('随便一段文字').kind, TargetKind.unknown);
      expect(BiliUrl.parse('').kind, TargetKind.unknown);
    });
  });

  group('Cookie 解析', () {
    test('请求头形式', () {
      final cookie = CookieParser.parse('SESSDATA=abc%2Cdef; bili_jct=jjj; DedeUserID=12345');
      expect(cookie.isComplete, isTrue);
      expect(cookie.sessData, 'abc%2Cdef');
      expect(cookie.dedeUserId, '12345');
    });

    test('Netscape cookie.txt', () {
      final text = [
        '# Netscape HTTP Cookie File',
        '.bilibili.com\tTRUE\t/\tFALSE\t1900000000\tSESSDATA\txyz',
        '#HttpOnly_.bilibili.com\tTRUE\t/\tFALSE\t1900000000\tbili_jct\tcsrf',
        '.bilibili.com\tTRUE\t/\tFALSE\t1900000000\tDedeUserID\t777',
      ].join('\n');
      final cookie = CookieParser.parse(text);
      expect(cookie.isComplete, isTrue);
      expect(cookie.sessData, 'xyz');
      expect(cookie.biliJct, 'csrf');
      expect(cookie.dedeUserId, '777');
    });

    test('Cookie: 前缀与不完整内容', () {
      final cookie = CookieParser.parse('Cookie: SESSDATA=only');
      expect(cookie.isEmpty, isFalse);
      expect(cookie.isComplete, isFalse);
      expect(CookieParser.parse('nothing here').isEmpty, isTrue);
    });
  });

  group('签名', () {
    test('mixin key 与公开测试向量一致', () {
      expect(mixinKeyFrom(_imgKey, _subKey), _mixinKey);
    });

    test('WBI 查询串与签名', () {
      final params = <String, String>{
        'support_multi_audio': 'true',
        'from_client': 'BROWSER',
        'avid': '80433022',
        'cid': '137649199',
        'fnval': '4048',
        'fnver': '0',
        'fourk': '1',
        'otype': 'json',
        'qn': '80',
        'try_look': '1',
        'gaia_source': 'pre-load',
        'wts': '1789000000',
      };
      expect(
        buildQuery(params),
        'avid=80433022&cid=137649199&fnval=4048&fnver=0&fourk=1&from_client=BROWSER'
        '&gaia_source=pre-load&otype=json&qn=80&support_multi_audio=true&try_look=1'
        '&wts=1789000000',
      );
      expect(wbiSign(params: params, mixinKey: _mixinKey), 'c2e2eb11a9466f5f91557936cb5cdc4d');
    });

    test('APP 签名', () {
      expect(
        appSign(
          query: 'appkey=783bbb7264451d82&local_id=0&ts=1789000000000',
          appSecret: '2653583c8873dea268ab9386918b1d65',
        ),
        'c1562186283d474b33d8f109b1c0a251',
      );
    });
  });

  group('流构建', () {
    test('视频流按清晰度降序、同清晰度优先 AVC', () {
      final videos = DashBuilder.videoStreams(_dashSample());
      expect(videos.length, 3);
      expect(videos.first.id, 80);
      expect(videos.first.codecs, 'avc1.640032');
      expect(videos.last.id, 32);
      expect(videos.first.backupUrls, isEmpty);
      expect(videos.last.backupUrls, hasLength(1));
    });

    test('音频流合并 flac 且按编号升序', () {
      final audios = DashBuilder.audioStreams(_dashSample());
      expect(audios.map((item) => item.id).toList(), [30232, 30251, 30280]);
      expect(audios.last.label, '192K');
    });

    test('时长优先取 dash.duration', () {
      expect(DashBuilder.durationOf(_dashSample()), 212);
      expect(DashBuilder.durationOf({'timelength': 212393}), 212);
    });
  });

  group('工具函数', () {
    test('体积与时长格式化', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatDuration(65), '01:05');
      expect(formatDuration(3725), '01:02:05');
    });

    test('文件名清洗', () {
      expect(sanitizeFileName('a/b:c*?"<>| d'), 'a b c d');
      expect(sanitizeFileName('   '), 'video');
    });

    test('凭据掩码不泄露原文', () {
      final masked = maskSecret('1234567890abcdef');
      expect(masked.contains('567890abc'), isFalse);
      expect(maskSecret('short'), '******');
    });
  });
}
