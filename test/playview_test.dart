import 'dart:convert';

import 'package:biliharbor/src/core/dash_builder.dart';
import 'package:biliharbor/src/core/playview.dart';
import 'package:flutter_test/flutter_test.dart';

/// 请求字节的 golden：用与宿主机 python 实测完全相同的一串参数编出来，
/// 服务端认的就是这段（fnval=4048|16384 时 REST 端点一律 -400，只有这里通）。
const String _requestGolden =
    'CJ+tgJjcshoQxYqQ04YBGH8gACjQnwEwADgCQAFKGW1haW4udWdjLXZpZGVvLWRldGFpbC4wLjBS'
    'E21haW4ubXktaGlzdG9yeS4wLjBgAg==';

/// 合成一份 PlayViewReply：129 HDR Vivid 与 120 4K 带地址，80 只列档位不给地址，
/// 另有一条 30280 音频。
const String _replyGolden =
    'CtcCCIEBEgZoZGZsdjIYvOAOKnUKGgiBARIGaGRmbHYyGglIRFIgVml2aWQwATgBElcKIGh0dHBz'
    'Oi8vZXhhbXBsZS5pbnZhbGlkL3YxMjkubTRzEiBodHRwczovL2V4YW1wbGUuaW52YWxpZC9iMTI5'
    'Lm00cxiHrUsgDCoIY2FmZWJhYmUwj04qUwoZCHgSBmhkZmx2MhoJ6LaF5riFIDRLMAE4ARI2CiBo'
    'dHRwczovL2V4YW1wbGUuaW52YWxpZC92MTIwLm00cxjOlY8BIAwqCGRlYWRiZWVmMLhFKhwKGghQ'
    'EgZoZGZsdjIaDOmrmOa4hSAxMDgwUDgBMlwIyOwBEiBodHRwczovL2V4YW1wbGUuaW52YWxpZC9h'
    'MTkyLm00cxohaHR0cHM6Ly9leGFtcGxlLmludmFsaWQvYTE5MmIubTRzII+wBygAMgYwZjBmMGY4'
    'qPreAQ==';

void main() {
  test('PlayViewReq 字节与实测一致', () {
    final request = PlayViewCodec.encodeRequest(
      aid: 116091942606495,
      cid: 36144678213,
      qn: 127,
    );
    expect(base64.encode(request), _requestGolden);
  });

  test('gRPC 帧头为大端长度', () {
    final framed = PlayViewCodec.frame(List<int>.filled(3, 7));
    expect(framed.sublist(0, 5), [0, 0, 0, 0, 3]);
    expect(PlayViewCodec.unframe(framed), List<int>.filled(3, 7));
  });

  test('残缺帧报错（压缩帧的 gzip 分支在 http1_test 里覆盖）', () {
    expect(() => PlayViewCodec.unframe([0, 0, 0, 0, 9, 1, 2]), throwsFormatException);
    expect(() => PlayViewCodec.unframe(<int>[]), throwsFormatException);
    expect(() => PlayViewCodec.unframe([0, 0, 0, 0, 0]), throwsFormatException);
  });

  test('PlayViewReply 还原成 dash 结构，129 带地址、80 只列档位', () {
    final data = PlayViewCodec.decodeReply(base64.decode(_replyGolden));
    final dash = data['dash'] as Map<String, dynamic>;
    final formats = (data['support_formats'] as List).cast<Map<String, dynamic>>();

    expect(data['accept_quality'], [129, 120, 80]);
    expect(data['timelength'], 241724);
    expect(dash['duration'], 241);
    expect(formats.map((item) => item['quality']), [129, 120, 80]);
    expect(formats.first['new_description'], 'HDR Vivid');
    expect(formats.first['need_vip'], isTrue);
    expect(formats.last['need_login'], isTrue);

    final videos = DashBuilder.videoStreams(data);
    expect(videos.map((stream) => stream.id), [129, 120]);
    expect(videos.first.label, 'HDR Vivid');
    expect(videos.first.codecs, 'hev1');
    expect(videos.first.url, 'https://example.invalid/v129.m4s');
    expect(videos.first.backupUrls, ['https://example.invalid/b129.m4s']);
    expect(videos.first.bandwidth, 1234567);

    final audios = DashBuilder.audioStreams(data);
    expect(audios.single.id, 30280);
    expect(audios.single.codecs, 'mp4a');
    expect(audios.single.url, 'https://example.invalid/a192.m4s');
  });

  test('合并后重新排序：129 排在 120 之前、125 之后', () {
    final base = DashBuilder.videoStreams({
      'dash': {
        'video': [
          {'id': 120, 'base_url': 'https://example.invalid/120', 'codecs': 'avc1'},
          {'id': 125, 'base_url': 'https://example.invalid/125', 'codecs': 'hev1'},
        ],
      },
    });
    final merged = DashBuilder.sortVideos([
      ...base,
      ...DashBuilder.videoStreams(PlayViewCodec.decodeReply(base64.decode(_replyGolden))),
    ]);
    expect(merged.map((stream) => stream.id), [125, 129, 120, 120]);
  });
}
