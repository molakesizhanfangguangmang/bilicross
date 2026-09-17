import 'package:bilicross/src/core/downloader.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

MediaStream _video(int id, String codecs) => MediaStream(
      id: id,
      label: qualityLabel(id),
      codecs: codecs,
      bandwidth: 1000000,
      url: 'https://cdn.example/v$id-$codecs.m4s',
      width: 1920,
      height: 1080,
    );

MediaStream _audio(int id, String codecs) => MediaStream(
      id: id,
      label: audioLabel(id),
      codecs: codecs,
      bandwidth: 128000,
      url: 'https://cdn.example/a$id.m4s',
    );

const String _pcUrl = 'https://cdn.example/upgcxcode/1/v.m4s?platform=pc&trid=abc';
const String _androidUrl = 'https://cdn.example/upgcxcode/1/v.m4s?platform=android&trid=abc';
const String _androidTvUrl = 'https://cdn.example/upgcxcode/1/v.m4s?platform=android_tv_yst&trid=abc';

void main() {
  group('按档位取流', () {
    final videos = <MediaStream>[
      _video(127, 'av01.0.12M.08'),
      _video(126, 'hev1.1.6.L150.90'),
      _video(120, 'avc1.640033'),
    ];

    test('同档位多编码时优先取编码一致的那条', () {
      final streams = <MediaStream>[
        _video(126, 'av01.0.09M.08'),
        _video(126, 'hev1.1.6.L150.90'),
      ];
      expect(pickStream(streams, 126, 'hev1.1.6.L150.90')?.codecs, 'hev1.1.6.L150.90');
    });

    test('编码对不上时取该档位第一条，而不是换成别的档位', () {
      expect(pickStream(videos, 126, 'avc1.640033')?.id, 126);
    });

    test('档位不在结果里时返回 null，绝不回落到别的档位', () {
      expect(pickStream(videos, 129, 'hev1.1.6.L150.90'), isNull);
    });

    test('档位 0 与负数表示不下载', () {
      expect(pickStream(videos, 0, ''), isNull);
      expect(pickStream(videos, -1, ''), isNull);
    });

    test('老任务（档位未记录）按原来的默认取法：视频第一条、音频最后一条', () {
      expect(resolveRecordedStream(videos, -1, '', fallbackFirst: true)?.id, 127);
      final audios = <MediaStream>[_audio(30216, 'mp4a.40.2'), _audio(30280, 'mp4a.40.2')];
      expect(resolveRecordedStream(audios, -1, '', fallbackFirst: false)?.id, 30280);
    });

    test('老任务遇到的列表为空时返回 null', () {
      expect(resolveRecordedStream(const <MediaStream>[], -1, '', fallbackFirst: true), isNull);
    });

    test('档位 0 依然表示不下载', () {
      expect(resolveRecordedStream(videos, 0, '', fallbackFirst: true), isNull);
    });
  });

  group('UA 与下载请求头', () {
    test('UA 留空时回落到内置短串，不做逐字透传', () {
      expect(effectiveUserAgent(''), kFallbackUserAgent);
      expect(effectiveUserAgent('   '), kFallbackUserAgent);
    });

    test('自定义 UA 原样使用', () {
      expect(effectiveUserAgent('  MyAgent/1.0 '), 'MyAgent/1.0');
    });

    test('网页地址带 Referer，移动端地址不带', () {
      final pc = StreamDownloader.headersFor(url: _pcUrl, userAgent: 'MyAgent/1.0');
      expect(pc['Referer'], kSiteReferer);
      expect(pc['Origin'], 'https://www.bilibili.com');
      expect(pc['User-Agent'], 'MyAgent/1.0');

      final android = StreamDownloader.headersFor(url: _androidUrl, userAgent: 'MyAgent/1.0');
      expect(android.containsKey('Referer'), isFalse);
      expect(android.containsKey('Origin'), isFalse);
      // 移动端地址固定短串：桌面长 UA 一律被 CDN 403，设置里的值在这类地址上不使用
      expect(android['User-Agent'], kFallbackUserAgent);

      final androidDesktop = StreamDownloader.headersFor(url: _androidUrl, userAgent: kWebUserAgent);
      expect(androidDesktop['User-Agent'], kFallbackUserAgent);
      expect(androidDesktop.containsKey('Referer'), isFalse);
    });

    test('android_tv_yst 这类平台也按移动端处理', () {
      final headers = StreamDownloader.headersFor(url: _androidTvUrl, userAgent: '');
      expect(headers.containsKey('Referer'), isFalse);
      expect(headers['User-Agent'], kFallbackUserAgent);
    });

    test('平台参数缺失时按网页处理', () {
      final headers = StreamDownloader.headersFor(url: 'https://cdn.example/v.m4s', userAgent: '');
      expect(headers['Referer'], kSiteReferer);
    });

    test('Range 只在需要时带上', () {
      final plain = StreamDownloader.headersFor(url: _pcUrl, userAgent: '');
      expect(plain.containsKey('Range'), isFalse);
      final ranged = StreamDownloader.headersFor(url: _pcUrl, userAgent: '', range: 'bytes=0-0');
      expect(ranged['Range'], 'bytes=0-0');
    });

    test('地址解析不了时不算移动端', () {
      expect(isAndroidPlatformUrl('not a url'), isFalse);
      expect(isAndroidPlatformUrl(_androidUrl), isTrue);
    });
  });

  group('任务记录', () {
    DownloadTask taskWith({required int videoId, required int audioId}) => DownloadTask(
          id: 'task-1',
          title: '示例',
          source: 'https://www.bilibili.com/video/BV1',
          infoId: 'BV1',
          page: 1,
          cid: 11,
          outputPath: '/tmp/示例.mp4',
          engine: 'dart',
          channel: 'APP',
          videoQualityId: videoId,
          audioQualityId: audioId,
          videoCodecs: 'av01.0.12M.08',
          audioCodecs: 'mp4a.40.2',
        );

    test('档位与编码随任务一起存取', () {
      final restored = DownloadTask.fromJson(taskWith(videoId: 127, audioId: 30280).toJson());
      expect(restored.videoQualityId, 127);
      expect(restored.audioQualityId, 30280);
      expect(restored.videoCodecs, 'av01.0.12M.08');
      expect(restored.audioCodecs, 'mp4a.40.2');
    });

    test('老任务存档里没有档位字段时记为未记录（-1）', () {
      final restored = DownloadTask.fromJson(<String, dynamic>{
        'id': 'old',
        'title': '旧任务',
        'source': 'https://www.bilibili.com/video/BV1',
        'info_id': 'BV1',
        'page': 1,
        'cid': 11,
        'output_path': '/tmp/旧任务.mp4',
        'engine': 'dart',
        'channel': 'WEB',
      });
      expect(restored.videoQualityId, -1);
      expect(restored.audioQualityId, -1);
      expect(restored.singleTrack, isFalse);
    });

    test('只选一条轨道的任务是单轨，不显示合并与清理入口', () {
      expect(taskWith(videoId: 127, audioId: 0).singleTrack, isTrue);
      expect(taskWith(videoId: 0, audioId: 30280).singleTrack, isTrue);
      expect(taskWith(videoId: 127, audioId: 30280).singleTrack, isFalse);
    });
  });
}
