import 'dart:io';

import 'bili_api.dart';
import 'fmp4.dart';

/// 合并结果：用的是哪条路径、写出多少字节、多长。
class MuxOutcome {
  const MuxOutcome({
    required this.engine,
    required this.bytes,
    required this.durationSeconds,
  });

  /// `ffmpeg` 或 `builtin`。
  final String engine;
  final int bytes;
  final double durationSeconds;

  String get engineLabel => engine == 'ffmpeg' ? 'ffmpeg' : '内置合并';
}

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

  static Future<void> remux({    required String ffmpeg,
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

  /// 合并音视频。默认先试 ffmpeg（输出标准 MP4，兼容性最好），
  /// 没有 ffmpeg 或 ffmpeg 失败时改用内置分片合并；两条都失败才报错。
  static Future<MuxOutcome> merge({
    required String ffmpegPath,
    required bool preferFfmpeg,
    required String videoPath,
    required String audioPath,
    required String outputPath,
    void Function(int written, int total)? onProgress,
  }) async {
    final hasFfmpeg = ffmpegPath.trim().isNotEmpty;
    final engines = <String>[
      if (hasFfmpeg && preferFfmpeg) 'ffmpeg',
      'builtin',
      if (hasFfmpeg && !preferFfmpeg) 'ffmpeg',
    ];
    final failures = <String>[];
    for (final engine in engines) {
      try {
        if (engine == 'ffmpeg') {
          await remux(
            ffmpeg: ffmpegPath,
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
          );
          return MuxOutcome(
            engine: engine,
            bytes: await File(outputPath).length(),
            durationSeconds: 0,
          );
        }
        final result = await Fmp4Merger.merge(
          videoPath: videoPath,
          audioPath: audioPath,
          outputPath: outputPath,
          onProgress: onProgress,
        );
        return MuxOutcome(
          engine: engine,
          bytes: result.bytes,
          durationSeconds: result.durationSeconds,
        );
      } catch (error) {
        final label = engine == 'ffmpeg' ? 'ffmpeg' : '内置合并';
        failures.add('$label：${error is BiliException ? error.message : error}');
      }
    }
    throw BiliException('合并失败（${failures.join('；')}）');
  }
}
