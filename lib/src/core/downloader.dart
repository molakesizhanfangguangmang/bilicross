import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'abort.dart';
import 'log_store.dart';
import 'models.dart';

/// 地址的 `platform` 参数以 android 开头（含 android_tv_yst 这类变体）。
/// 这类地址由 gRPC PlayView 等移动端接口签发：CDN 不接受它带 Referer，
/// 桌面长 UA 也会被拒，实测「短 UA + 不带 Referer」才回 200/206。
bool isAndroidPlatformUrl(String url) {
  final platform = Uri.tryParse(url)?.queryParameters['platform'];
  return platform != null && platform.startsWith('android');
}

/// 建连超时：只管 TCP 与 TLS 握手。
const Duration kConnectTimeout = Duration(seconds: 20);

/// 流空闲超时：这么多秒一个字节都没来，就当作连接已经掉线，断开重连。
/// 没有它，CDN 不发 FIN 就是无限等待——旧版「卡在最后一点、日志里什么都不写」
/// 就是这么来的。
const Duration kStreamIdleTimeout = Duration(seconds: 30);

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
///
/// 每个 `download()` 用自己的 HTTP 客户端：取消时只掐自己这一条连接，
/// 不牵连同一个进程里其它并发任务，也不牵连解析用的接口客户端。
class StreamDownloader {
  StreamDownloader({
    required this.userAgent,
    this.proxy = '',
    this.idleTimeout = kStreamIdleTimeout,
  });

  final String userAgent;
  final String proxy;

  /// 流空闲超时，测试里会调短。
  final Duration idleTimeout;

  /// 分段的最小粒度：再小就只剩连接开销。
  static const int minChunkBytes = 1 << 20;

  /// 单条地址最多试几次。只有超时、掉线这类可续传的失败才重试；
  /// HTTP 状态码类的错误重试也没用，直接换备用地址。
  static const int maxAttempts = 3;

  Future<DownloadResult> download({
    required String url,
    required String targetPath,
    required AbortControl control,
    List<String> backups = const [],
    int parts = 1,
    void Function(int received, int total)? onProgress,
  }) async {
    final session = _Session.open(proxy: proxy);
    control.bind(session.abort);
    try {
      final candidates = <String>[url, ...backups];
      final name = targetPath.split(Platform.pathSeparator).last;
      LogStore.instance.add(
        '下载',
        isAndroidPlatformUrl(url)
            ? '$name：移动端地址，不带 Referer，UA=$kFallbackUserAgent'
            : '$name：网页地址，带 Referer，UA=${effectiveUserAgent(userAgent)}',
      );
      Object? lastError;
      for (var index = 0; index < candidates.length; index++) {
        control.throwIfAborted();
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
                  client: session.client,
                  url: candidate,
                  targetPath: targetPath,
                  parts: parts,
                  onProgress: onProgress,
                  control: control,
                );
                if (result != null) {
                  LogStore.instance.add(
                    '下载',
                    '$name：分段下载完成，${result.bytes} 字节',
                  );
                  return result;
                }
                LogStore.instance.add('下载', '$name：分段不可用（服务端不认 Range 或文件过小），改单连接');
              } on TaskAborted {
                rethrow;
              } catch (error) {
                // 分段失败不丢这个地址：退回单连接再试一次。
                // 分段留下的 .partN 对单连接没用，留着只会变成迷惑人的残留。
                lastError = error;
                await _clearChunks(targetPath);
                LogStore.instance.add('下载', '$name：分段下载失败（$error），改单连接');
              }
            }
          }
          final result = await _downloadOne(
            client: session.client,
            url: candidate,
            targetPath: targetPath,
            onProgress: onProgress,
            control: control,
          );
          LogStore.instance.add(
            '下载',
            '$name：单连接完成，${result.bytes} 字节${result.resumed ? '（续传）' : ''}',
          );
          return result;
        } on TaskAborted {
          rethrow;
        } catch (error) {
          // 掐连接造成的报错也走这里，先按取消归类。
          control.throwIfAborted();
          lastError = error;
          LogStore.instance.add('下载', '$name：地址 $index 失败（$error）');
        }
      }
      throw HttpException('下载失败：${lastError ?? '没有可用地址'}');
    } finally {
      control.unbind();
      session.dispose();
    }
  }

  Future<bool> _hasPendingPart(String targetPath) async {
    final part = File('$targetPath.part');
    return await part.exists() && await part.length() > 0;
  }

  /// 问一次总长度，顺便确认服务端认 Range。不认就返回 null。
  Future<int?> _probeTotal({required http.Client client, required String url}) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers
          .addAll(headersFor(url: url, userAgent: userAgent, range: 'bytes=0-0'));
      final response = await client.send(request);
      await response.stream.timeout(idleTimeout).drain<void>();
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
  /// UA 也分开：移动端地址对桌面长串一律 403，固定用短串，不看设置里的值；
  /// 网页地址用设置里的 UA，留空回落短串（空 UA 会被 CDN 拒）。
  static Map<String, String> headersFor({
    required String url,
    required String userAgent,
    String? range,
  }) {
    final android = isAndroidPlatformUrl(url);
    return {
      'User-Agent': android ? kFallbackUserAgent : effectiveUserAgent(userAgent),
      if (!android) 'Referer': kSiteReferer,
      if (!android) 'Origin': 'https://www.bilibili.com',
      'Accept': '*/*',
      if (range != null) 'Range': range,
    };
  }

  /// 分段下载。返回 null 表示「这次不分段」，由调用方退回单连接。
  Future<DownloadResult?> _downloadParts({
    required http.Client client,
    required String url,
    required String targetPath,
    required AbortControl control,
    required int parts,
    void Function(int received, int total)? onProgress,
  }) async {
    final total = await _probeTotal(client: client, url: url);
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
          client: client,
          url: url,
          chunkPath: _chunkPath(targetPath, index),
          start: index * chunkSize,
          end: _chunkEnd(index, chunkSize, total),
          control: control,
          onBytes: (bytes) {
            received[index] = bytes;
            report();
          },
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
          control.throwIfAborted();
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

  /// 丢掉全部分段文件。退回单连接之前调用：那边只看 `.part`，分段留着没用。
  Future<void> _clearChunks(String targetPath) async {
    for (var index = 0; index < 16; index++) {
      final chunk = File(_chunkPath(targetPath, index));
      if (await chunk.exists()) await chunk.delete();
    }
  }

  static int _chunkEnd(int index, int chunkSize, int total) {
    final end = index * chunkSize + chunkSize - 1;
    return end > total - 1 ? total - 1 : end;
  }

  /// 下载一段，返回是否续传。
  Future<bool> _downloadChunk({
    required http.Client client,
    required String url,
    required String chunkPath,
    required int start,
    required int end,
    required AbortControl control,
    required void Function(int bytes) onBytes,
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
      control.throwIfAborted();
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
          throw _StatusError(response.statusCode);
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
          await for (final chunk in response.stream.timeout(idleTimeout)) {
            control.throwIfAborted();
            sink.add(chunk);
            current += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastReport).inMilliseconds >= 200) {
              lastReport = now;
              onBytes(current);
            }
            // 这一段收满就停，不等服务端关流。
            if (current >= length) break;
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
      } on TaskAborted {
        // 暂停/结束时把真实落盘长度报上去，界面上的进度不会退回上一格。
        final onDisk = await file.exists() ? await file.length() : 0;
        onBytes(onDisk);
        rethrow;
      } catch (error) {
        control.throwIfAborted();
        if (error is _StatusError) rethrow;
        lastError = error;
        have = await file.exists() ? await file.length() : 0;
      }
    }
    throw HttpException('分段下载失败：${lastError ?? '未知错误'}');
  }

  /// 单连接下载。掉线或超时算可续传的失败，按 `.part` 断点重连几次再放弃。
  Future<DownloadResult> _downloadOne({
    required http.Client client,
    required String url,
    required String targetPath,
    required AbortControl control,
    void Function(int received, int total)? onProgress,
  }) async {
    final part = File('$targetPath.part');
    await part.parent.create(recursive: true);
    final name = targetPath.split(Platform.pathSeparator).last;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      control.throwIfAborted();
      try {
        return await _downloadOneAttempt(
          client: client,
          url: url,
          targetPath: targetPath,
          part: part,
          control: control,
          onProgress: onProgress,
        );
      } on TaskAborted {
        rethrow;
      } on _StatusError catch (error) {
        throw HttpException('HTTP ${error.status}');
      } catch (error) {
        control.throwIfAborted();
        lastError = error;
        if (attempt < maxAttempts) {
          LogStore.instance.add('下载', '$name：第 $attempt 次中断（$error），从断点重连');
        }
      }
    }
    throw HttpException('$name 重试 $maxAttempts 次都中断：${lastError ?? '未知错误'}');
  }

  Future<DownloadResult> _downloadOneAttempt({
    required http.Client client,
    required String url,
    required String targetPath,
    required File part,
    required AbortControl control,
    void Function(int received, int total)? onProgress,
  }) async {
    var startAt = await part.exists() ? await part.length() : 0;
    control.throwIfAborted();

    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(headersFor(
      url: url,
      userAgent: userAgent,
      range: startAt > 0 ? 'bytes=$startAt-' : null,
    ));

    final response = await client.send(request);
    if (response.statusCode == 416) {
      // 本地这一段已经到顶：`bytes=N-` 越界了。大概率是「字节收满但服务端没发 FIN」
      // 留下的完整 .part，先问一次总长，确实到齐就当场收工，否则清掉重来。
      await response.stream.drain<void>();
      final probed = await _probeTotal(client: client, url: url);
      if (probed != null && probed == startAt) {
        final target = File(targetPath);
        if (await target.exists()) await target.delete();
        final finished = await part.rename(targetPath);
        return DownloadResult(path: finished.path, bytes: startAt, resumed: true);
      }
      if (await part.exists()) await part.delete();
      throw HttpException('HTTP 416');
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>();
      throw _StatusError(response.statusCode);
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

    final declared = int.tryParse(response.headers['content-length'] ?? '');
    final total = declared == null ? 0 : startAt + declared;

    final sink = part.openWrite(mode: FileMode.append);
    var received = startAt;
    var lastReport = DateTime.now();
    try {
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        control.throwIfAborted();
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 200) {
          lastReport = now;
          onProgress?.call(received, total);
        }
        // 收满即停，不等服务端关流——旧版就是在这里永久等下去的。
        if (total > 0 && received >= total) break;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress?.call(received, total);

    if (total > 0 && received < total) {
      // 服务端提前关流。旧版会把半截文件当成品改名收工，
      // 现在退回重连续传，续不上就让任务失败，分片留着。
      throw HttpException('连接提前结束：$received / $total');
    }

    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    final finished = await part.rename(targetPath);
    return DownloadResult(path: finished.path, bytes: received, resumed: resumed);
  }
}

/// HTTP 状态码错误：同一地址重试没有意义，只有换地址才有用。
class _StatusError implements Exception {
  const _StatusError(this.status);

  final int status;

  @override
  String toString() => 'HTTP $status';
}

/// 一次 `download()` 的网络会话。每个下载自己一份客户端，
/// 取消时 `close(force: true)` 直接掐掉连接，让卡在 `await` 里的读取立刻失败。
class _Session {
  _Session._(this._inner) : client = IOClient(_inner);

  final HttpClient _inner;
  final http.Client client;

  static _Session open({required String proxy}) {
    final inner = HttpClient()..connectionTimeout = kConnectTimeout;
    final trimmed = proxy.trim();
    if (trimmed.isNotEmpty) {
      inner.findProxy = (uri) => 'PROXY $trimmed';
    }
    return _Session._(inner);
  }

  void abort() {
    try {
      client.close();
    } catch (_) {
      // 已经关掉了。
    }
    try {
      _inner.close(force: true);
    } catch (_) {
      // 同上。
    }
  }

  void dispose() => abort();
}

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
