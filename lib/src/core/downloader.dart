import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'log_store.dart';
import 'models.dart';

/// 地址的 `platform` 参数以 android 开头（含 android_tv_yst 这类变体）。
/// 这类地址由 gRPC PlayView 等移动端接口签发：CDN 不接受它带 Referer，
/// 桌面长 UA 也会被拒，实测「短 UA + 不带 Referer」才回 200/206。
bool isAndroidPlatformUrl(String url) {
  final platform = Uri.tryParse(url)?.queryParameters['platform'];
  return platform != null && platform.startsWith('android');
}

class DownloadResult {
  const DownloadResult({
    required this.path,
    required this.bytes,
    required this.resumed,
  });

  final String path;
  final int bytes;
  final bool resumed;
}

/// 单文件下载：断点续传 + 备用地址回落 + 可选的同文件多连接分段。
///
/// 分段下载不是必需路径：服务端不支持 Range、文件太小、或本地已有单连接留下的
/// `.part` 时会自动退回单连接。每一段写在 `目标.partN` 里，各自可以续传，
/// 全部到齐后再顺序拼成 `目标.part` 并改名。任一段失败会让整个文件退回单连接重来。
class StreamDownloader {
  StreamDownloader({required this.client, required this.userAgent});

  final http.Client client;
  final String userAgent;

  /// 分段的最小粒度：再小就只剩连接开销。
  static const int minChunkBytes = 1 << 20;

  Future<DownloadResult> download({
    required String url,
    required String targetPath,
    List<String> backups = const [],
    int parts = 1,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final candidates = <String>[url, ...backups];
    final name = targetPath.split(Platform.pathSeparator).last;
    Object? lastError;
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      if (candidate.isEmpty) continue;
      if (index > 0) {
        LogStore.instance.add('下载', '$name：主地址失败，改用备用地址 $index');
      }
      try {
        if (parts > 1) {
          if (await _hasPendingPart(targetPath)) {
            LogStore.instance.add('下载', '$name：已有半截 .part，沿用单连接续传');
          } else {
            try {
              final result = await _downloadParts(
                url: candidate,
                targetPath: targetPath,
                parts: parts,
                onProgress: onProgress,
                isCancelled: isCancelled,
              );
              if (result != null) {
                LogStore.instance.add(
                  '下载',
                  '$name：分段下载完成，${result.bytes} 字节',
                );
                return result;
              }
              LogStore.instance.add('下载', '$name：分段不可用（服务端不认 Range 或文件过小），改单连接');
            } on _DownloadCancelled {
              rethrow;
            } catch (error) {
              // 分段失败不丢这个地址：退回单连接再试一次。
              lastError = error;
              LogStore.instance.add('下载', '$name：分段下载失败（$error），改单连接');
            }
          }
        }
        final result = await _downloadOne(
          url: candidate,
          targetPath: targetPath,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
        LogStore.instance.add(
          '下载',
          '$name：单连接完成，${result.bytes} 字节${result.resumed ? '（续传）' : ''}',
        );
        return result;
      } on _DownloadCancelled {
        rethrow;
      } catch (error) {
        lastError = error;
        LogStore.instance.add('下载', '$name：地址 $index 失败（$error）');
      }
    }
    throw HttpException('下载失败：${lastError ?? '没有可用地址'}');
  }

  Future<bool> _hasPendingPart(String targetPath) async {
    final part = File('$targetPath.part');
    return await part.exists() && await part.length() > 0;
  }

  /// 问一次总长度，顺便确认服务端认 Range。不认就返回 null。
  Future<int?> _probeTotal({required String url}) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(headersFor(url: url, userAgent: userAgent, range: 'bytes=0-0'));
      final response = await client.send(request);
      await response.stream.drain<void>();
      if (response.statusCode != 206) return null;
      final contentRange = response.headers['content-range'];
      if (contentRange == null) return null;
      final slash = contentRange.lastIndexOf('/');
      if (slash < 0) return null;
      final total = int.tryParse(contentRange.substring(slash + 1));
      if (total == null || total <= 0) return null;
      return total;
    } catch (_) {
      return null;
    }
  }

  /// 下载请求头。移动端地址不带 Referer/Origin（带了会被 CDN 403），网页地址反之必须带。
  /// UA 留空时回落到短串：空 UA 在网页地址上会被拒，桌面长串在移动端地址上会被拒。
  static Map<String, String> headersFor({
    required String url,
    required String userAgent,
    String? range,
  }) {
    final android = isAndroidPlatformUrl(url);
    return {
      'User-Agent': effectiveUserAgent(userAgent),
      if (!android) 'Referer': kSiteReferer,
      if (!android) 'Origin': 'https://www.bilibili.com',
      'Accept': '*/*',
      if (range != null) 'Range': range,
    };
  }

  /// 分段下载。返回 null 表示「这次不分段」，由调用方退回单连接。
  Future<DownloadResult?> _downloadParts({
    required String url,
    required String targetPath,
    required int parts,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final total = await _probeTotal(url: url);
    if (total == null || total < minChunkBytes * 2) return null;

    var count = parts;
    var chunkSize = (total / count).ceil();
    if (chunkSize < minChunkBytes) {
      count = (total ~/ minChunkBytes).clamp(2, parts);
      chunkSize = (total / count).ceil();
    }
    if (count < 2) return null;

    final received = List<int>.filled(count, 0);
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    void report() {
      final now = DateTime.now();
      if (now.difference(lastReport).inMilliseconds < 200) return;
      lastReport = now;
      var sum = 0;
      for (final value in received) {
        sum += value;
      }
      onProgress?.call(sum, total);
    }

    final resumedFlags = await Future.wait<bool>(<Future<bool>>[
      for (var index = 0; index < count; index++)
        _downloadChunk(
          url: url,
          chunkPath: _chunkPath(targetPath, index),
          start: index * chunkSize,
          end: _chunkEnd(index, chunkSize, total),
          onBytes: (bytes) {
            received[index] = bytes;
            report();
          },
          isCancelled: isCancelled,
        ),
    ]);

    var written = 0;
    for (var index = 0; index < count; index++) {
      final expected = _chunkEnd(index, chunkSize, total) - index * chunkSize + 1;
      final length = await File(_chunkPath(targetPath, index)).length();
      if (length != expected) {
        throw HttpException('分段 $index 长度不符：$length != $expected');
      }
      written += length;
    }
    if (written != total) {
      throw HttpException('分段总长度不符：$written != $total');
    }

    final part = File('$targetPath.part');
    if (await part.exists()) await part.delete();
    final sink = part.openWrite();
    try {
      for (var index = 0; index < count; index++) {
        final chunkFile = File(_chunkPath(targetPath, index));
        await for (final chunk in chunkFile.openRead()) {
          if (isCancelled != null && isCancelled()) {
            throw _DownloadCancelled();
          }
          sink.add(chunk);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    for (var index = 0; index < count; index++) {
      final chunkFile = File(_chunkPath(targetPath, index));
      if (await chunkFile.exists()) await chunkFile.delete();
    }

    onProgress?.call(total, total);
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    final finished = await part.rename(targetPath);
    return DownloadResult(
      path: finished.path,
      bytes: total,
      resumed: resumedFlags.any((flag) => flag),
    );
  }

  static String _chunkPath(String targetPath, int index) => '$targetPath.part$index';

  static int _chunkEnd(int index, int chunkSize, int total) {
    final end = index * chunkSize + chunkSize - 1;
    return end > total - 1 ? total - 1 : end;
  }

  /// 下载一段，返回是否续传。
  Future<bool> _downloadChunk({
    required String url,
    required String chunkPath,
    required int start,
    required int end,
    required void Function(int bytes) onBytes,
    bool Function()? isCancelled,
  }) async {
    final file = File(chunkPath);
    await file.parent.create(recursive: true);
    final length = end - start + 1;
    var have = await file.exists() ? await file.length() : 0;
    if (have > length) {
      await file.delete();
      have = 0;
    }
    final resumed = have > 0;
    if (have == length) {
      onBytes(have);
      return resumed;
    }

    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final request = http.Request('GET', Uri.parse(url));
        request.headers.addAll(
          headersFor(url: url, userAgent: userAgent, range: 'bytes=${start + have}-$end'),
        );
        final response = await client.send(request);
        if (response.statusCode == 416) {
          // 已经下满了，服务端用 416 回答越界的 Range。
          final current = await file.exists() ? await file.length() : 0;
          if (current == length) {
            onBytes(current);
            return resumed;
          }
          throw HttpException('HTTP 416');
        }
        if (response.statusCode != 206 && response.statusCode != 200) {
          await response.stream.drain<void>();
          throw HttpException('HTTP ${response.statusCode}');
        }
        if (response.statusCode == 200) {
          // 服务端忽略 Range：这一段的偏移就不可信了，交给单连接路径重来。
          await response.stream.drain<void>();
          throw HttpException('服务端不支持分段请求');
        }

        final sink = file.openWrite(mode: FileMode.append);
        var current = have;
        var lastReport = DateTime.now();
        try {
          await for (final chunk in response.stream) {
            if (isCancelled != null && isCancelled()) {
              throw _DownloadCancelled();
            }
            sink.add(chunk);
            current += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastReport).inMilliseconds >= 200) {
              lastReport = now;
              onBytes(current);
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        onBytes(current);
        if (current != length) {
          throw HttpException('分段下载中断：$current != $length');
        }
        return resumed;
      } on _DownloadCancelled {
        rethrow;
      } catch (error) {
        lastError = error;
        have = await file.exists() ? await file.length() : 0;
      }
    }
    throw HttpException('分段下载失败：${lastError ?? '未知错误'}');
  }

  Future<DownloadResult> _downloadOne({
    required String url,
    required String targetPath,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final part = File('$targetPath.part');
    await part.parent.create(recursive: true);
    var startAt = await part.exists() ? await part.length() : 0;

    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(headersFor(
      url: url,
      userAgent: userAgent,
      range: startAt > 0 ? 'bytes=$startAt-' : null,
    ));

    final response = await client.send(request);
    if (response.statusCode >= 400) {
      await response.stream.drain<void>();
      throw HttpException('HTTP ${response.statusCode}');
    }

    var resumed = false;
    if (startAt > 0 && response.statusCode == 206) {
      resumed = true;
    } else if (response.statusCode == 200) {
      // 服务端忽略 Range 时从头写，避免把整段流追加到半截文件后面。
      startAt = 0;
      resumed = false;
      if (await part.exists()) await part.delete();
    }

    final totalHeader = response.headers['content-length'];
    final total = startAt + (int.tryParse(totalHeader ?? '') ?? 0);

    final sink = part.openWrite(mode: FileMode.append);
    var received = startAt;
    var lastReport = DateTime.now();
    try {
      await for (final chunk in response.stream) {
        if (isCancelled != null && isCancelled()) {
          throw _DownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 200) {
          lastReport = now;
          onProgress?.call(received, total);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress?.call(received, total);

    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    final finished = await part.rename(targetPath);
    return DownloadResult(path: finished.path, bytes: received, resumed: resumed);
  }
}

class _DownloadCancelled implements Exception {}

/// 合并前先确认两个分片都已落盘且非空。
bool hasUsableFile(String path) {
  final file = File(path);
  return file.existsSync() && file.lengthSync() > 0;
}

/// 一个下载目标可能留下的全部文件：成品本身、`.part`、`.partN`。
/// 分段并发上限是 8，这里多扫一倍留余量。
List<String> artifactPaths(String targetPath) {
  if (targetPath.isEmpty) return const [];
  return <String>[
    targetPath,
    '$targetPath.part',
    for (var index = 0; index < 16; index++) '$targetPath.part$index',
  ];
}

/// 删掉某个目标文件的全部痕迹，返回删掉的文件数。
Future<int> removeArtifacts(String targetPath) async {
  var removed = 0;
  for (final path in artifactPaths(targetPath)) {
    final file = File(path);
    if (!await file.exists()) continue;
    await file.delete();
    removed++;
  }
  return removed;
}
