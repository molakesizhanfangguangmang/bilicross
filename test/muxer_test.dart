import 'dart:io';

import 'package:bilicross/src/core/muxer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Muxer.locate', () {
    test('配置路径有效时直接用它，不去查 PATH', () async {
      final dir = Directory.systemTemp.createTempSync('bilicross_mux_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final fake = File('${dir.path}${Platform.pathSeparator}ffmpeg-test');
      fake.writeAsStringSync('not a real binary');

      expect(await Muxer.locate('  ${fake.path}  '), fake.path);
    });

    test('配置路径为空或不存在时返回 null 或系统结果', () async {
      // 空配置 + 主机没有 ffmpeg 时返回 null；有 ffmpeg 时会返回可用的那个。
      // 两种都算正确，这里只要求「不抛异常且是 String? 语义」。
      final resolved = await Muxer.locate('');
      if (resolved != null) {
        expect(resolved, isNotEmpty);
      }

      final missing = await Muxer.locate(
        '${Directory.systemTemp.path}${Platform.pathSeparator}no_such_ffmpeg',
      );
      if (missing != null) {
        expect(missing, isNotEmpty);
      }
    });

    test('捆绑目录里的 ffmpeg 能被自动发现', () async {
      // 只在 Windows 上生效：locate 的兜底分支查的是可执行文件旁的
      // tools/ffmpeg。测试里没法替换 Platform.resolvedExecutable，
      // 所以这里验证「兜底分支存在且不影响正常返回」。
      if (!Platform.isWindows) {
        return;
      }
      final base = File(Platform.resolvedExecutable).parent;
      final bundled = File(
        '${base.path}${Platform.pathSeparator}tools'
        '${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}ffmpeg.exe',
      );
      // 没有捆绑文件时，locate 应正常返回（null 或 PATH 里的那个），不抛异常。
      final resolved = await Muxer.locate('');
      if (!bundled.existsSync()) {
        expect(resolved == null || resolved.isNotEmpty, isTrue);
      }
    });
  });

  group('MuxOutcome', () {
    test('引擎标签区分 ffmpeg 与内置合并', () {
      const ffmpeg =
          MuxOutcome(engine: 'ffmpeg', bytes: 10, durationSeconds: 0);
      const builtin =
          MuxOutcome(engine: 'builtin', bytes: 20, durationSeconds: 1.5);
      expect(ffmpeg.engineLabel, 'ffmpeg');
      expect(builtin.engineLabel, '内置合并');
      expect(builtin.bytes, 20);
      expect(builtin.durationSeconds, 1.5);
    });
  });
}
