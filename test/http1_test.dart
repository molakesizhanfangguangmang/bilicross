import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bilicross/src/core/http1.dart';
import 'package:bilicross/src/core/playview.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实抓包的响应（2026-09-17 对 grpc.biliapi.net 的 PlayView 发一条匿名请求所得）：
/// chunked 分块 5769/1460/1451/1458，终止块之后还有 154 字节 trailer。
/// dart:io 的 HttpClient 正是读到这段 trailer 才抛
/// `Failed to parse HTTP, 98 does not match 13`，所以拿它当夹具。
const String _fixturePath = 'test/fixtures/playview_chunked_trailer.bin';
const int _fixtureBodyLength = 10138;
const String _fixtureBodySha256 =
    'e79c547303ec6eb4068d11914e835f9bc940d8a8cd4d0d151129903357e3f718';

Uint8List _fixture() {
  final file = File(_fixturePath);
  if (!file.existsSync()) throw StateError('缺少抓包夹具：$_fixturePath');
  return file.readAsBytesSync();
}

Stream<List<int>> _drip(Uint8List data) =>
    Stream<List<int>>.fromIterable(List<List<int>>.generate(data.length, (i) => [data[i]]));

void main() {
  group('真实抓包', () {
    test('chunked 终止块之后的 trailer 被跳过，正文完整', () async {
      final raw = _fixture();
      final response = await readHttp1Response(Stream<List<int>>.value(raw));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'application/grpc+proto');
      expect(response.headers['transfer-encoding'], 'chunked');
      expect(response.body.length, _fixtureBodyLength);
      expect(sha256.convert(response.body).toString(), _fixtureBodySha256);

      expect(response.trailers['grpc-status'], '0');
      expect(response.trailers['bili-status-code'], '0');
      expect(response.trailers['x-bili-trace-id'], isNotEmpty);

      final payload = PlayViewCodec.unframe(response.body);
      expect(response.body.first, 0);
      expect(payload.length, _fixtureBodyLength - 5);
    });

    test('逐字节投递得到同样的正文', () async {
      final response = await readHttp1Response(_drip(_fixture()));
      expect(response.body.length, _fixtureBodyLength);
      expect(sha256.convert(response.body).toString(), _fixtureBodySha256);
      expect(response.trailers['grpc-status'], '0');
    });
  });

  group('响应形态', () {
    test('chunked 且没有 trailer', () async {
      final response = await readHttp1Response(Stream.value(
        ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n'),
      ));
      expect(response.body, ascii.encode('hello'));
      expect(response.trailers, isEmpty);
    });

    test('chunked 终止块后直接断开', () async {
      final response = await readHttp1Response(Stream.value(
        ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n'),
      ));
      expect(response.body, ascii.encode('abc'));
    });

    test('带 Content-Length', () async {
      final response = await readHttp1Response(Stream.value(
        ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbody'),
      ));
      expect(response.body, ascii.encode('body'));
    });

    test('既无长度也无 chunked 时读到连接关闭', () async {
      final response = await readHttp1Response(
        Stream<List<int>>.fromIterable([
          ascii.encode('HTTP/1.1 200 OK\r\n\r\n'),
          ascii.encode('raw'),
        ]),
      );
      expect(response.body, ascii.encode('raw'));
    });

    test('长度行非法时报错', () async {
      expect(
        () => readHttp1Response(Stream.value(
          ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n'),
        )),
        throwsA(isA<Http1Exception>()),
      );
    });

    test('Content-Length 强于实际正文时报错', () async {
      expect(
        () => readHttp1Response(Stream.value(
          ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort'),
        )),
        throwsA(isA<Http1Exception>()),
      );
    });
  });

  group('请求构造', () {
    test('头与正文按 HTTP/1.1 拼接', () {
      final request = buildRequest(
        host: 'grpc.biliapi.net',
        path: '/bilibili.app.playurl.v1.PlayURL/PlayView',
        headers: const {'Content-Type': 'application/grpc+proto'},
        body: const [1, 2, 3],
      );
      final text = ascii.decode(request.sublist(0, request.length - 3));
      expect(text.startsWith('POST /bilibili.app.playurl.v1.PlayURL/PlayView HTTP/1.1\r\n'), isTrue);
      expect(text.contains('Host: grpc.biliapi.net\r\n'), isTrue);
      expect(text.contains('Content-Type: application/grpc+proto\r\n'), isTrue);
      expect(text.contains('Content-Length: 3\r\n'), isTrue);
      expect(text.endsWith('Connection: close\r\n\r\n'), isTrue);
      expect(request.sublist(request.length - 3), [1, 2, 3]);
    });

    test('头里带换行直接拒绝', () {
      expect(
        () => buildRequest(
          host: 'h',
          path: '/',
          headers: const {'X': 'a\r\nInjected: b'},
          body: const [],
        ),
        throwsA(isA<Http1Exception>()),
      );
    });
  });

  group('代理', () {
    test('host:port 与带前缀两种写法都能解析', () {
      expect(parseProxyTarget('192.168.1.112:7890'), (host: '192.168.1.112', port: 7890));
      expect(parseProxyTarget('http://192.168.1.112:7890'), (host: '192.168.1.112', port: 7890));
      expect(parseProxyTarget('  127.0.0.1:1080  '), (host: '127.0.0.1', port: 1080));
    });

    test('空串表示直连', () {
      expect(parseProxyTarget(''), isNull);
      expect(parseProxyTarget('   '), isNull);
    });

    test('不支持的形态明确报错', () {
      expect(() => parseProxyTarget('socks5://1.2.3.4:1080'), throwsA(isA<Http1Exception>()));
      expect(() => parseProxyTarget('no-port'), throwsA(isA<Http1Exception>()));
      expect(() => parseProxyTarget('host:0'), throwsA(isA<Http1Exception>()));
      expect(() => parseProxyTarget('host:abc'), throwsA(isA<Http1Exception>()));
    });

    test('CONNECT 请求形态', () {
      expect(
        buildConnectRequest('grpc.biliapi.net', 443),
        'CONNECT grpc.biliapi.net:443 HTTP/1.1\r\nHost: grpc.biliapi.net:443\r\n\r\n',
      );
    });

    test('状态行解析', () {
      expect(parseStatusCode('HTTP/1.1 200 Connection established'), 200);
      expect(parseStatusCode('HTTP/1.1 407 Proxy Authentication Required'), 407);
      expect(() => parseStatusCode('garbage'), throwsA(isA<Http1Exception>()));
      expect(() => parseStatusCode('HTTP/1.1'), throwsA(isA<Http1Exception>()));
    });
  });

  group('gRPC 帧', () {
    test('压缩帧按 gzip 解', () {
      final data = utf8.encode('playview payload');
      // 帧头里的长度是压缩后的长度（gRPC 规定），不是解压后的。
      final compressed = gzip.encode(data);
      final frame = <int>[1, ...compressed.length.toBytes(4), ...compressed];
      expect(PlayViewCodec.unframe(frame), data);
    });

    test('不认识的压缩标志报错', () {
      expect(
        () => PlayViewCodec.unframe([2, 0, 0, 0, 1, 9]),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

extension on int {
  List<int> toBytes(int count) =>
      List<int>.generate(count, (i) => (this >> (8 * (count - 1 - i))) & 0xff);
}
