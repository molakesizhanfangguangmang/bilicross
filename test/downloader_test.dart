import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bilicross/src/core/abort.dart';
import 'package:bilicross/src/core/downloader.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final List<int> rangeStarts = <int>[];
  int pieceSize = 1 << 20;
  Duration pieceDelay = Duration.zero;

  /// 写出这么多字节后就停住：不写、不关、也不发 FIN，用来复现「卡在最后一点」。
  int? stallAfter;

  /// 声明完整长度，但只写这么多字节就关流，用来复现「服务端提前关流」。
  int? truncateAfter;

  bool supportRangeFlag = true;

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
      rangeStarts.add(start);
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes $start-$last/${bytes.length}');
      request.response.headers.contentLength = last - start + 1;
      _writePieces(request.response, start, last);
      return;
    }
    request.response.statusCode = 200;
    request.response.headers.contentLength = bytes.length;
    _writePieces(request.response, 0, bytes.length - 1);
  }

  /// 分片写出，可以按 [pieceDelay] 放慢，用来制造「传到一半」的时机。
  void _writePieces(HttpResponse response, int start, int last) {
    unawaited(() async {
      try {
        var cursor = start;
        var written = 0;
        while (cursor <= last) {
          final stop = cursor + pieceSize - 1 > last ? last : cursor + pieceSize - 1;
          final slice = bytes.sublist(cursor, stop + 1);
          response.add(slice);
          await response.flush();
          written += slice.length;
          cursor = stop + 1;
          if (truncateAfter != null && written >= truncateAfter!) {
            await response.close();
            return;
          }
          if (stallAfter != null && written >= stallAfter!) {
            // 保持连接开着，什么都不做。
            return;
          }
          if (pieceDelay > Duration.zero) {
            await Future<void>.delayed(pieceDelay);
          }
        }
        await response.close();
      } catch (_) {
        // 客户端中途断开是这类测试的预期，忽略即可。
        try {
          await response.close();
        } catch (_) {
          // 连接已经断了。
        }
      }
    }());
  }

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

  setUp(() async {
    work = await Directory.systemTemp.createTemp('bilicross-dl');
  });

  tearDown(() async {
    if (await work.exists()) {
      await work.delete(recursive: true);
    }
  });

  String target_(String name) => '${work.path}${Platform.pathSeparator}$name';

  test('单连接下载写入目标文件并清掉临时分片', () async {
    final server = await _Server.start(_payload(3 << 20));
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
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
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');
    final progress = <int>[];

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
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
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
      parts: 4,
    );

    expect(result.bytes, (3 << 20));
    expect(await _read(target), server.bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('文件太小就不分片', () async {
    final server = await _Server.start(_payload(512 << 10));
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');

    await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
      parts: 4,
    );

    expect(await _read(target), server.bytes);
    expect(server.rangeRequests, 1);
  });

  test('已有半截 .part 时按断点续传补齐', () async {
    final bytes = _payload(2 << 20);
    final server = await _Server.start(bytes);
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final head = 700 << 10;
    await File('$target.part').writeAsBytes(bytes.sublist(0, head));
    final downloader = StreamDownloader(userAgent: 'test');

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
      parts: 4,
    );

    expect(result.resumed, isTrue);
    expect(await _read(target), bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('分段下载能从已有分段文件继续', () async {
    final bytes = _payload(3 << 20);
    final server = await _Server.start(bytes);
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');
    final head = 512 << 10;
    await File('$target.part0').writeAsBytes(bytes.sublist(0, head));

    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
      parts: 4,
    );

    expect(result.resumed, isTrue);
    expect(server.rangeStarts, contains(head));
    expect(await _read(target), bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('暂停保留分片，继续后按断点补齐', () async {
    final bytes = _payload(4 << 20);
    final server = await _Server.start(bytes);
    server.pieceSize = 32 << 10;
    server.pieceDelay = const Duration(milliseconds: 20);
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');
    final control = AbortControl();

    await expectLater(
      downloader.download(
        url: '${server.origin}/file',
        targetPath: target,
        control: control,
        parts: 4,
        onProgress: (received, total) {
          if (received > 0 && !control.aborted) control.pause();
        },
      ),
      throwsA(isA<TaskAborted>()),
    );

    expect(control.reason, AbortReason.pause);
    expect(await File(target).exists(), isFalse);
    final stopped = await _leftovers(work);
    expect(stopped, isNotEmpty);
    expect(stopped.where((name) => name.contains('.part')), isNotEmpty);

    server.pieceDelay = Duration.zero;
    final result = await downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: AbortControl(),
      parts: 4,
    );

    expect(result.bytes, (4 << 20));
    expect(await _read(target), bytes);
    expect(await _leftovers(work), ['video.m4s']);
  });

  test('卡住的连接能被强制结束掐断', () async {
    final server = await _Server.start(_payload(2 << 20));
    server.pieceSize = 64 << 10;
    server.stallAfter = 64 << 10;
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(
      userAgent: 'test',
      idleTimeout: const Duration(seconds: 30),
    );
    final control = AbortControl();

    final future = downloader.download(
      url: '${server.origin}/file',
      targetPath: target,
      control: control,
      parts: 1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await File('$target.part').exists(), isTrue);

    final watch = Stopwatch()..start();
    control.stop();
    await expectLater(
      future.timeout(const Duration(seconds: 8)),
      throwsA(isA<TaskAborted>()),
    );
    watch.stop();
    // 不是靠 30 秒的空闲超时收场的，是掐连接当场断的。
    expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
  });

  test('连接卡住不发数据时靠空闲超时断开，不永久等待', () async {
    final server = await _Server.start(_payload(2 << 20));
    server.pieceSize = 64 << 10;
    server.stallAfter = 64 << 10;
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(
      userAgent: 'test',
      idleTimeout: const Duration(milliseconds: 500),
    );

    // 每次重连都在同一个位置停住，所以最终失败；关键是它自己退出来了，没挂着。
    await expectLater(
      downloader.download(
        url: '${server.origin}/file',
        targetPath: target,
        control: AbortControl(),
        parts: 1,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(await File(target).exists(), isFalse);
    expect(await File('$target.part').length(), greaterThanOrEqualTo(64 << 10));
  });

  test('服务端提前关流不算完成，留下分片待续传', () async {
    final bytes = _payload(2 << 20);
    final server = await _Server.start(bytes);
    server.pieceSize = 64 << 10;
    server.truncateAfter = 64 << 10;
    addTearDown(server.stop);
    final target = target_('video.m4s');
    final downloader = StreamDownloader(userAgent: 'test');

    await expectLater(
      downloader.download(
        url: '${server.origin}/file',
        targetPath: target,
        control: AbortControl(),
        parts: 1,
      ),
      throwsA(isA<HttpException>()),
    );

    // 半截文件不再被当成成品改名收工。
    expect(await File(target).exists(), isFalse);
    final part = File('$target.part');
    expect(await part.exists(), isTrue);
    expect(await part.length(), lessThan(bytes.length));
  });

  test('清理残留会删掉成品与全部分片', () async {
    final target = target_('video.m4s');
    await File(target).writeAsBytes(_payload(16));
    await File('$target.part').writeAsBytes(_payload(16));
    await File('$target.part0').writeAsBytes(_payload(16));
    await File('$target.part3').writeAsBytes(_payload(16));
    await File(target_('keep.m4s')).writeAsBytes(_payload(16));

    final removed = await removeArtifacts(target);

    expect(removed, 4);
    expect(await _leftovers(work), ['keep.m4s']);
  });
}
