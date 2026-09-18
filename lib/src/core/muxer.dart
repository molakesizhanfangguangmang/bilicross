import 'dart:convert';
import 'dart:io';

import 'abort.dart';
import 'bili_api.dart';
import 'fmp4.dart';
import 'log_store.dart';

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
    // 捆绑的 ffmpeg：随包放在可执行文件旁的 tools/ffmpeg 下。系统 PATH 找不到时兜底，
    // 这样便携版 / 安装版不用让用户自己配 PATH 也能用上 ffmpeg 合并。
    if (Platform.isWindows) {
      final base = File(Platform.resolvedExecutable).parent.path;
      final sep = Platform.pathSeparator;
      for (final name in _candidates) {
        final bundled = File('$base${sep}tools${sep}ffmpeg${sep}$name');
        if (!bundled.existsSync()) continue;
        try {
          final result = await Process.run(bundled.path, ['-version']);
          if (result.exitCode == 0) return bundled.path;
        } on ProcessException {
          continue;
        }
      }
    }
    return null;
  }

  /// 合并用 `Process.start` 而不是 `Process.run`：只有拿到进程句柄，
  /// 「强制结束」才能真的把 ffmpeg 掐掉，否则它会在后台把文件写完。
  static Future<void> remux({
    required String ffmpeg,
    required String videoPath,
    required String audioPath,
    required String outputPath,
    AbortControl? control,
  }) async {
    if (!File(videoPath).existsSync()) {
      throw BiliException('视频分片不存在：$videoPath');
    }
    if (!File(audioPath).existsSync()) {
      throw BiliException('音频分片不存在：$audioPath');
    }
    final process = await Process.start(ffmpeg, [
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
    final stderrText = process.stderr.transform(utf8.decoder).join();
    final stdoutDrain = process.stdout.drain<void>();
    control?.bind(() => process.kill());
    final int exitCode;
    try {
      exitCode = await process.exitCode;
    } finally {
      control?.unbind();
    }
    final stderr = await stderrText;
    await stdoutDrain;
    if (exitCode != 0) {
      throw BiliException(
        '合并失败：${stderr.trim().isEmpty ? 'ffmpeg 退出码 $exitCode' : stderr.trim()}',
      );
    }
    if (!File(outputPath).existsSync()) {
      throw BiliException('合并后没有生成文件');
    }
  }

  /// 合并音视频。默认先试 ffmpeg（输出标准 MP4，兼容性最好），
  /// 没有 ffmpeg 或 ffmpeg 失败时改用内置分片合并；两条都失败才报错。
  ///
  /// 传入 [control] 后，强制结束会杀掉正在跑的 ffmpeg（或在下一个内置合并
  /// 检查点停下），并且不再往下试第二条路径。
  static Future<MuxOutcome> merge({
    required String ffmpegPath,
    required bool preferFfmpeg,
    required String videoPath,
    required String audioPath,
    required String outputPath,
    AbortControl? control,
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
      control?.throwIfAborted();
      final label = engine == 'ffmpeg' ? 'ffmpeg' : '内置合并';
      try {
        if (engine == 'ffmpeg') {
          await remux(
            ffmpeg: ffmpegPath,
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            control: control,
          );
          final bytes = await File(outputPath).length();
          LogStore.instance.add('合并', 'ffmpeg 合并完成：$bytes 字节');
          return MuxOutcome(
            engine: engine,
            bytes: bytes,
            durationSeconds: 0,
          );
        }
        final result = await Fmp4Merger.merge(
          videoPath: videoPath,
          audioPath: audioPath,
          outputPath: outputPath,
          onProgress: (written, total) {
            // 内置合并是纯 Dart 循环，检查点就放在进度回调里。
            control?.throwIfAborted();
            onProgress?.call(written, total);
          },
        );
        LogStore.instance.add('合并', '内置合并完成：${result.bytes} 字节');
        return MuxOutcome(
          engine: engine,
          bytes: result.bytes,
          durationSeconds: result.durationSeconds,
        );
      } catch (error) {
        // 取消不是失败：不换下一条路径，也不要把它写成「合并失败」。
        if (control != null && control.aborted) {
          throw TaskAborted(control.reason!);
        }
        failures.add('$label：${error is BiliException ? error.message : error}');
        LogStore.instance.add(
          '合并',
          '$label 失败：${error is BiliException ? error.message : error}'
          '${engines.last == engine ? '' : '，改用下一条路径'}',
        );
      }
    }
    throw BiliException('合并失败（${failures.join('；')}）');
  }
}
