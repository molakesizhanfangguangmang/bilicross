import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_check.dart' show readPackageName;

/// 流空闲超过此时长没有新数据就判下载失败，避免极慢网络下进度走满却一直卡在
/// 「正在下载」。
const Duration kRolloutIdleTimeout = Duration(seconds: 30);

/// 灰度内测包下载的结果。
enum RolloutDownloadStatus {
  /// 下载完成，文件已落到本地。
  done,

  /// token 不对。
  badToken,

  /// 服务端没有对应文件。
  notFound,

  /// 其它失败（网络、写盘等）。
  failed,
}

/// 下载灰度内测包，落盘后返回 (status, path)。
///
/// 走 VPS 下载接口，带 `deviceKey` + token。下载用 stream 分块写，避免整包进内存。
Future<(RolloutDownloadStatus, String?)> downloadRolloutApk({
  required String deviceKey,
  required String token,
  String? targetDir,
  String baseUrl = 'https://bili.culture-see.de5.net',
  http.Client? client,
  void Function(int received, int total)? onProgress,
}) async {
  final owned = client == null;
  final agent = client ?? http.Client();
  try {
    final pkg = await readPackageName();
    final uri = Uri.parse(
      '$baseUrl/v1/rollout/download?deviceKey='
      '${Uri.encodeQueryComponent(deviceKey)}'
      '&pkg=${Uri.encodeQueryComponent(pkg)}'
      '&token=${Uri.encodeQueryComponent(token)}',
    );
    final response = await agent.send(http.Request('GET', uri));
    if (response.statusCode == 403) {
      return (RolloutDownloadStatus.badToken, null);
    }
    if (response.statusCode == 404) {
      return (RolloutDownloadStatus.notFound, null);
    }
    if (response.statusCode != 200) {
      return (RolloutDownloadStatus.failed, null);
    }
    final total = response.contentLength ?? 0;
    final target = targetDir?.trim();
    final String dirPath;
    if (target == null || target.isEmpty) {
      dirPath = (await getTemporaryDirectory()).path;
    } else {
      // 新建一个固定子目录，避免和用户下载目录里的其它文件混在一起。
      dirPath = '$target${Platform.pathSeparator}逸轨内测';
    }
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    final file = File('$dirPath${Platform.pathSeparator}BiliCross-internal.apk');
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(kRolloutIdleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return (RolloutDownloadStatus.done, file.path);
  } catch (_) {
    return (RolloutDownloadStatus.failed, null);
  } finally {
    if (owned) agent.close();
  }
}
