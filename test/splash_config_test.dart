import 'dart:io';

import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/splash_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('开屏时长收敛', () {
    test('区间内的值原样保留', () {
      expect(clampSplashSeconds(0), 0);
      expect(clampSplashSeconds(1.5), 1.5);
      expect(clampSplashSeconds(5), 5);
    });

    test('超出上限收到 5 秒', () {
      expect(clampSplashSeconds(9), kSplashMaxSeconds);
      expect(clampSplashSeconds(999), kSplashMaxSeconds);
    });

    test('负值收到 0', () {
      expect(clampSplashSeconds(-3), 0);
    });

    test('NaN 回落到默认 2 秒', () {
      expect(clampSplashSeconds(double.nan), 2.0);
    });
  });

  group('开屏配置读写', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bilicross_splash_');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('数据目录下路径固定为 splash.img', () {
      final file = splashImageFile(root);
      expect(file.path.endsWith(kSplashImageName), isTrue);
      expect(file.parent.path, root.path);
    });

    test('保存后图出现在数据目录，原文件删掉也不受影响', () async {
      final source = File('${root.path}${Platform.pathSeparator}src.png');
      await source.writeAsBytes(const <int>[1, 2, 3, 4, 5]);

      final ok = await saveSplashImage(root, source.path);
      expect(ok, isTrue);

      // 复制而不是引用：删掉来源，副本还在。
      await source.delete();
      final saved = splashImageFile(root);
      expect(saved.existsSync(), isTrue);
      expect(await saved.readAsBytes(), <int>[1, 2, 3, 4, 5]);
    });

    test('再次保存会覆盖旧图', () async {
      final first = File('${root.path}${Platform.pathSeparator}a.png');
      await first.writeAsBytes(const <int>[1, 1, 1]);
      await saveSplashImage(root, first.path);

      final second = File('${root.path}${Platform.pathSeparator}b.png');
      await second.writeAsBytes(const <int>[2, 2, 2, 2]);
      final ok = await saveSplashImage(root, second.path);

      expect(ok, isTrue);
      expect(await splashImageFile(root).readAsBytes(), <int>[2, 2, 2, 2]);
    });

    test('来源不存在时返回 false，不抛异常', () async {
      final ok = await saveSplashImage(
        root,
        '${root.path}${Platform.pathSeparator}nope.png',
      );
      expect(ok, isFalse);
    });

    test('清除后再清除一次也不报错', () async {
      final src = File('${root.path}${Platform.pathSeparator}c.png');
      await src.writeAsBytes(const <int>[9]);
      await saveSplashImage(root, src.path);

      await removeSplashImage(root);
      expect(splashImageFile(root).existsSync(), isFalse);

      // 幂等：没有图也不掷异常。
      await removeSplashImage(root);
    });
  });

  group('设置项序列化', () {
    test('新字段有默认值：默认关闭、停留 2 秒', () {
      final settings = AppSettings.fromJson(const <String, dynamic>{});
      expect(settings.splashEnabled, isFalse);
      expect(settings.splashSeconds, 2.0);
    });

    test('落盘后能原样读回', () {
      final settings = AppSettings()
        ..splashEnabled = true
        ..splashSeconds = 3.5;
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.splashEnabled, isTrue);
      expect(restored.splashSeconds, 3.5);
    });

    test('配置里的越界时长读回时被收敛', () {
      final restored = AppSettings.fromJson(const <String, dynamic>{
        'splash_seconds': 42.0,
      });
      expect(restored.splashSeconds, kSplashMaxSeconds);

      final negative = AppSettings.fromJson(const <String, dynamic>{
        'splash_seconds': -1.0,
      });
      expect(negative.splashSeconds, 0);
    });
  });
}
