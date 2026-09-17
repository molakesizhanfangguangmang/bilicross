import 'dart:io';

import 'bili_api.dart';

/// 混流只做流复制，不转码。
class Muxer {
  const Muxer._();

  static const List<String> _candidates = ['ffmpeg', 'ffmpeg.exe'];

  /// 已配置路径优先；否则在 PATH 里找。找不到返回 null，由界面提示。
  static Future<String?> locate(String configured) async {
    final trimmed = configured.trim();
    if (trimmed.isNotEmpty && File(trimmed).existsSync()) {
      return trimmed;
    }
    for (final name in _candidates) {
      try {
        final result = await Process.run(name, ['-version']);
        if (result.exitCode == 0) return name;
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  static Future<void> remux({
    required String ffmpeg,
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    if (!File(videoPath).existsSync()) {
      throw BiliException('视频分片不存在：$videoPath');
    }
    if (!File(audioPath).existsSync()) {
      throw BiliException('音频分片不存在：$audioPath');
    }
    final result = await Process.run(ffmpeg, [
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      videoPath,
      '-i',
      audioPath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c',
      'copy',
      outputPath,
    ]);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw BiliException('合并失败：${stderr.isEmpty ? 'ffmpeg 退出码 ${result.exitCode}' : stderr}');
    }
    if (!File(outputPath).existsSync()) {
      throw BiliException('合并后没有生成文件');
    }
  }
}
