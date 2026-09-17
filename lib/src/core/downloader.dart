import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

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

/// 单文件下载：断点续传 + 备用地址回落。
///
/// 每个文件只用一条连接。分片多连接会显著提速，但会引入并发写盘与合并的复杂度，
/// 首版先保住可恢复与可重试，连接数留到后续版本。
class StreamDownloader {
  StreamDownloader({required this.client, required this.userAgent});

  final http.Client client;
  final String userAgent;

  Future<DownloadResult> download({
    required String url,
    required String targetPath,
    List<String> backups = const [],
    String referer = 'https://www.bilibili.com/',
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final candidates = <String>[url, ...backups];
    Object? lastError;
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      if (candidate.isEmpty) continue;
      try {
        return await _downloadOne(
          url: candidate,
          targetPath: targetPath,
          referer: referer,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      } on _DownloadCancelled {
        rethrow;
      } catch (error) {
        lastError = error;
      }
    }
    throw HttpException('下载失败：${lastError ?? '没有可用地址'}');
  }

  Future<DownloadResult> _downloadOne({
    required String url,
    required String targetPath,
    required String referer,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final part = File('$targetPath.part');
    await part.parent.create(recursive: true);
    var startAt = await part.exists() ? await part.length() : 0;

    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll({
      'User-Agent': userAgent,
      'Referer': referer,
      'Origin': 'https://www.bilibili.com',
      'Accept': '*/*',
      if (startAt > 0) 'Range': 'bytes=$startAt-',
    });

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
