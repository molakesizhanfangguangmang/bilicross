import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'pb.dart';

/// APP 端 PlayView（`grpc.biliapi.net/bilibili.app.playurl.v1.PlayURL/PlayView`）的编解码。
///
/// 为什么单独开这条通道：fnval 的 16384 位（HDR Vivid）只有这个端点认，
/// REST 的 `/x/player/playurl` 与 `/x/player/wbi/playurl` 带上它一律返回 -400，
/// 所以 qn=129 只能从这里取。字段号与固定参数取自 BBDownNext 的
/// `APP/Payload/playviewreq.proto`、`APP/Response/playviewreply.proto` 与 `AppHelper.cs`。
class PlayViewCodec {
  const PlayViewCodec._();

  /// dash(16) + HDR(64) + 4K(128) + 杜比音频(256) + 杜比视界(512) + 8K(1024)
  /// + AV1(2048) + HDR Vivid(16384)。
  static const int fnvalVivid = 4048 | 16384;

  /// PlayViewReq.CodeType.CODE265：HDR Vivid 只有 HEVC/AV1 能承载，
  /// 与 BBDownNext 默认一致走 HEVC。
  static const int codecHevc = 2;

  /// gRPC 方法路径。
  static const String method = '/bilibili.app.playurl.v1.PlayURL/PlayView';

  static const String host = 'grpc.biliapi.net';

  static const String spmid = 'main.ugc-video-detail.0.0';
  static const String fromSpmid = 'main.my-history.0.0';

  /// 客户端伪装成安卓粉版，与 APP 端 REST 请求同源。
  static const String userAgent =
      'Dalvik/2.1.0 (Linux; U; Android 11; M2012K11AC Build/RKQ1.200826.002) 7.32.0 '
      'os/android model/M2012K11AC mobi_app/android build/7320200 '
      'channel/xiaomi_cn_tv.danmaku.bili_zm20200902 innerVer/7320200 osVer/11 '
      'network/2 grpc-java-cronet/1.36.1';

  static const String _mobiApp = 'android';
  static const String _channel = 'xiaomi_cn_tv.danmaku.bili_zm20200902';
  static const int _build = 7320200;
  static const String _versionName = '7.32.0';
  static const String _brand = 'M2012K11AC';
  static const String _model = 'Build/RKQ1.200826.002';
  static const String _osVer = '11';

  /// buvid 只作指纹位使用，服务端不校验其真实性；没有它反而可能被判成异常客户端。
  static final String _buvid = _randomBuvid();

  static String _randomBuvid() {
    const alphabet = '0123456789ABCDEF';
    final random = Random();
    final buffer = StringBuffer('XY');
    for (var index = 0; index < 32; index++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// PlayViewReq。UGC 侧 aid 放在 epId 字段，这是 BBDownNext 的实测用法。
  static Uint8List encodeRequest({
    required int aid,
    required int cid,
    int qn = 127,
    int fnval = fnvalVivid,
    int codecType = codecHevc,
  }) {
    final writer = PbWriter();
    writer.varint(1, aid);
    writer.varint(2, cid);
    writer.varint(3, qn);
    writer.varint(4, 0);
    writer.varint(5, fnval);
    writer.varint(6, 0);
    writer.varint(7, 2);
    writer.varint(8, 1);
    writer.str(9, spmid);
    writer.str(10, fromSpmid);
    writer.varint(12, codecType);
    return writer.toBytes();
  }

  /// gRPC 的 5 字节帧头：压缩标志 0 + 大端长度。
  static Uint8List frame(List<int> message) {
    final framed = Uint8List(message.length + 5);
    framed[0] = 0;
    framed[1] = (message.length >> 24) & 0xff;
    framed[2] = (message.length >> 16) & 0xff;
    framed[3] = (message.length >> 8) & 0xff;
    framed[4] = message.length & 0xff;
    framed.setRange(5, framed.length, message);
    return framed;
  }

  /// 去掉帧头，返回 protobuf 正文；压缩响应与残缺帧直接报错。
  static Uint8List unframe(List<int> payload) {
    if (payload.isEmpty) {
      throw const FormatException('gRPC 响应为空');
    }
    if (payload[0] != 0) {
      throw FormatException('gRPC 响应使用了压缩（标志 ${payload[0]}）');
    }
    if (payload.length < 5) {
      throw const FormatException('gRPC 响应缺少帧头');
    }
    final length = (payload[1] << 24) | (payload[2] << 16) | (payload[3] << 8) | payload[4];
    if (length <= 0 || length + 5 > payload.length) {
      throw FormatException('gRPC 帧长度不合法（$length）');
    }
    return Uint8List.fromList(payload.sublist(5, 5 + length));
  }

  /// x-bili-*-bin 头：值是 protobuf 的 base64（gRPC 规定 -bin 头走 base64）。
  static Map<String, String> binaryHeaders({String accessToken = ''}) => {
        'x-bili-fawkes-req-bin': base64.encode(_fawkesReq()),
        'x-bili-metadata-bin': base64.encode(_metadata(accessToken)),
        'x-bili-device-bin': base64.encode(_device()),
        'x-bili-network-bin': base64.encode(_network()),
        'x-bili-locale-bin': base64.encode(_locale()),
        'x-bili-restriction-bin': '',
        'x-bili-exps-bin': '',
      };

  static Uint8List _fawkesReq() {
    final writer = PbWriter();
    writer.str(1, 'android64');
    writer.str(2, 'prod');
    writer.str(3, 'dedf8669');
    return writer.toBytes();
  }

  static Uint8List _metadata(String accessToken) {
    final writer = PbWriter();
    if (accessToken.isNotEmpty) writer.str(1, accessToken);
    writer.str(2, _mobiApp);
    writer.varint(4, _build);
    writer.str(5, _channel);
    writer.str(6, _buvid);
    writer.str(7, 'android');
    return writer.toBytes();
  }

  static Uint8List _device() {
    final writer = PbWriter();
    writer.varint(1, 1);
    writer.varint(2, _build);
    writer.str(3, _buvid);
    writer.str(4, _mobiApp);
    writer.str(5, 'android');
    writer.str(6, 'phone');
    writer.str(7, _channel);
    writer.str(8, _brand);
    writer.str(9, _model);
    writer.str(10, _osVer);
    writer.str(13, _versionName);
    return writer.toBytes();
  }

  static Uint8List _network() {
    final writer = PbWriter();
    writer.varint(1, 1);
    writer.str(2, '46007');
    return writer.toBytes();
  }

  static Uint8List _locale() {
    final inner = PbWriter()
      ..str(1, 'zh')
      ..str(3, 'CN');
    final writer = PbWriter()..bytes(1, inner.toBytes());
    return writer.toBytes();
  }

  /// codecid -> 编码短名，供同清晰度去重与展示使用。
  static const Map<int, String> _videoCodecs = {7: 'avc1', 12: 'hev1', 13: 'av01'};

  static String _audioCodecs(int id) {
    if (id == 30250) return 'ec-3';
    if (id == 30251) return 'flac';
    return 'mp4a';
  }

  /// PlayViewReply -> 与 REST playurl 同形的 Map，好让 DashBuilder 直接吃。
  ///
  /// 档位列表（含 need_vip/need_login）与可下载地址分开：未登录或非大会员时
  /// 服务端照样列出高档位，但不给 base_url，这类档位只进 accept_quality。
  static Map<String, dynamic> decodeReply(List<int> body) {
    final root = pbFields(body);
    final videoInfoRaw = pbChunk(root, 1);
    if (videoInfoRaw == null) {
      throw const FormatException('PlayView 响应里没有 videoInfo');
    }
    final videoInfo = pbFields(videoInfoRaw);
    final timelength = pbInt(videoInfo, 3) ?? 0;

    final qualities = <int>[];
    final descriptions = <String>[];
    final formats = <Map<String, dynamic>>[];
    final videos = <Map<String, dynamic>>[];

    for (final raw in pbChunks(videoInfo, 5)) {
      final item = pbFields(raw);
      final infoRaw = pbChunk(item, 1);
      final dashRaw = pbChunk(item, 2);

      var quality = 0;
      var description = '';
      var needVip = false;
      var needLogin = false;
      if (infoRaw != null) {
        final info = pbFields(infoRaw);
        quality = pbInt(info, 1) ?? 0;
        description = pbText(info, 3);
        needVip = (pbInt(info, 6) ?? 0) != 0;
        needLogin = (pbInt(info, 7) ?? 0) != 0;
      }
      if (quality == 0) continue;
      qualities.add(quality);
      descriptions.add(description);
      formats.add({
        'quality': quality,
        'new_description': description,
        'need_vip': needVip,
        'need_login': needLogin,
      });

      if (dashRaw == null) continue;
      final dashFields = pbFields(dashRaw);
      final url = pbText(dashFields, 1);
      if (url.isEmpty) continue;
      final codecid = pbInt(dashFields, 4) ?? 0;
      videos.add({
        'id': quality,
        'base_url': url,
        'backup_url': _texts(dashFields, 2),
        'bandwidth': pbInt(dashFields, 3) ?? 0,
        'codecid': codecid,
        'codecs': _videoCodecs[codecid] ?? '',
        'size': pbInt(dashFields, 6) ?? 0,
        'md5': pbText(dashFields, 5),
      });
    }

    final audios = <Map<String, dynamic>>[];
    for (final raw in pbChunks(videoInfo, 6)) {
      final item = _audioItem(pbFields(raw));
      if (item != null) audios.add(item);
    }

    final dashMap = <String, dynamic>{
      'duration': timelength ~/ 1000,
      'video': videos,
      'audio': audios,
    };
    final dolby = _dolby(pbChunk(videoInfo, 7));
    if (dolby != null) dashMap['dolby'] = dolby;
    final flac = _dolby(pbChunk(videoInfo, 9));
    if (flac != null) dashMap['flac'] = flac;

    return {
      'quality': qualities.isEmpty ? 0 : qualities.first,
      'timelength': timelength,
      'accept_quality': qualities,
      'accept_description': descriptions,
      'support_formats': formats,
      'dash': dashMap,
    };
  }

  /// 杜比伴音（field 7）与 Hi-Res（field 9）都是 DolbyItem{type, audio}。
  static Map<String, dynamic>? _dolby(Uint8List? raw) {
    if (raw == null) return null;
    final fields = pbFields(raw);
    final audioRaw = pbChunk(fields, 2);
    final item = audioRaw == null ? null : _audioItem(pbFields(audioRaw));
    if (item == null) return null;
    return {'type': pbInt(fields, 1) ?? 0, 'audio': [item]};
  }

  static Map<String, dynamic>? _audioItem(List<PbField> fields) {
    final id = pbInt(fields, 1) ?? 0;
    final url = pbText(fields, 2);
    if (id == 0 || url.isEmpty) return null;
    return {
      'id': id,
      'base_url': url,
      'backup_url': _texts(fields, 3),
      'bandwidth': pbInt(fields, 4) ?? 0,
      'codecid': pbInt(fields, 5) ?? 0,
      'codecs': _audioCodecs(id),
      'size': pbInt(fields, 7) ?? 0,
      'md5': pbText(fields, 6),
    };
  }

  static List<String> _texts(List<PbField> fields, int number) => [
        for (final raw in pbChunks(fields, number))
          if (raw.isNotEmpty) utf8.decode(raw, allowMalformed: true),
      ];

  /// 响应里的档位展示名，仅用于日志。
  static String describe(Map<String, dynamic> data) {
    final formats = data['support_formats'];
    if (formats is! List) return '';
    return formats
        .whereType<Map>()
        .map((item) => '${item['quality']}/${item['new_description']}')
        .join('、');
  }
}
