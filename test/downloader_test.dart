import 'dart:io';
import 'dart:typed_data';

import 'package:biliharbor/src/core/downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Uint8List _payload(int length) {
  final bytes = Uint8List(length);
  for (var index = 0; index < length; index++) {
    bytes[index] = index % 251;
  }
  return bytes;
}

class _Server {
  _Server(this.server, this.bytes);

  final HttpServer server;
  final Uint8List bytes;
  int rangeRequests = 0;

  String get origin => 'http://${server.address.host}:${server.port}';

  static Future<_Server> start(Uint8List bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final holder = _Server(server, bytes);
    server.listen(holder._handle);
    return holder;
  }

  void _handle(HttpRequest request) {
    if (!request.uri.path.startsWith('/file')) {
      request.response.statusCode = 404;
      request.response.close();
      return;
    }
    final range = request.headers.value('range');
    if (supportRangeFlag && range != null && range.startsWith('bytes=')) {
      rangeRequests++;
      final spec = range.substring('bytes='.length);
      final dash = spec.indexOf('-');
      final start = int.parse(spec.substring(0, dash));
      final endText = spec.substring(dash + 1);
      final end = endText.isEmpty ? bytes.length - 1 : int.parse(endText);
      if (start >= bytes.length) {
        request.response.statusCode = 416;
        request.response.close();
        return;
      }
      final last = end < bytes.length - 1 ? end : bytes.length - 1;
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes $start-$last/${bytes.length}');
      request.response.headers.contentLength = last - start + 1;
      request.response.add(bytes.sublist(start, last + 1));
      request.response.close();
      return;
    }
    request.response.statusCode = 200;
    request.response.headers.contentLength = bytes.length;
    request.response.add(bytes);
    request.response.close();
  }

  bool supportRangeFlag = true;

  Future<void> stop() => server.close(force: true);
}

Future<Uint8List> _read(String path) => File(path).readAsBytes();

Future<List<String>> _leftovers(Directory dir) async {
  final names = <String>[];
  await for (final entity in dir.list()) {
    if (entity is File) names.add(entity.uri.pathSegments.last);
  }
  names.sort();
  return names;
}

void main() {
  late Directory work;
  late http.Client client;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('biliharbor-dl');
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    if (await work.exists()) {
      await work.delete(recursive: true);
    }
  });

  test('单连接下载写入目标文件并清掉临时分片', () async {
    final server = await _Server.start(_payload(3 << 20));
    addTearDown(server.stop);
    final target = '${work.path}${Platform.pathSeparator}video.m4s';
    final downloader = StreamDownloader(client: client, userAgent: 'test');

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      parts: 1,
    );

    expect(result.bytes, (3 << 20));
    expect(result.resumed, isFalse);
    expect(await _read(target), server.bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('多连接分段下载结果与源一致', () async {
    final server = await _Server.start(_payload(3 << 20));
    addTearDown(server.stop);
    final target = '${work.path}${Platform.pathSeparator}video.m4s';
    final downloader = StreamDownloader(client: client, userAgent: 'test');
    final progress = <int>[];

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      parts: 4,
      onProgress: (received, total) => progress.add(received),
    );

    expect(result.bytes, (3 << 20));
    expect(await _read(target), server.bytes);
    expect(await _leftovers(work), ['video.m4s']);
    expect(server.rangeRequests, greaterThanOrEqualTo(4));
    expect(progress, isNotEmpty);
    expect(progress.last, (3 << 20));
  });

  test('服务端不支持分段时自动退回单连接', () async {
    final server = await _Server.start(_payload(3 << 20));
    server.supportRangeFlag = false;
    addTearDown(server.stop);
    final target = '${work.path}${Platform.pathSeparator}video.m4s';
    final downloader = StreamDownloader(client: client, userAgent: 'test');

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      parts: 4,
    );

    expect(result.bytes, (3 << 20));
    expect(await _read(target), server.bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('文件太小就不分片', () async {
    final server = await _Server.start(_payload(512 << 10));
    addTearDown(server.stop);
    final target = '${work.path}${Platform.pathSeparator}video.m4s';
    final downloader = StreamDownloader(client: client, userAgent: 'test');

    await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      parts: 4,
    );

    expect(await _read(target), server.bytes);
    expect(server.rangeRequests, 1);
  });

  test('已有半截 .part 时按断点续传补齐', () async {
    final bytes = _payload(2 << 20);
    final server = await _Server.start(bytes);
    addTearDown(server.stop);
    final target = '${work.path}${Platform.pathSeparator}video.m4s';
    final head = 700 << 10;
    await File('$target.part').writeAsBytes(bytes.sublist(0, head));
    final downloader = StreamDownloader(client: client, userAgent: 'test');

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      parts: 4,
    );

    expect(result.resumed, isTrue);
    expect(await _read(target), bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('分段下载中断后重跑能补齐', () async {
    final bytes = _payload(4 << 20);
    final server = await _Server.start(bytes);
    addTearDown(server.stop);
    final target = '${work.path}${Platform.pathSeparator}video.m4s';
    final downloader = StreamDownloader(client: client, userAgent: 'test');

    var cancelled = false;
    await expectLater(
      downloader.download(
        url: '${server.origin}/file',
        targetPath: target,
        parts: 4,
        onProgress: (received, total) {
          if (received > (1 << 20)) cancelled = true;
        },
        isCancelled: () => cancelled,
      ),
      throwsA(isA<Exception>()),
    );

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      parts: 4,
    );

    expect(result.bytes, (4 << 20));
    expect(await _read(target), bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });
}
