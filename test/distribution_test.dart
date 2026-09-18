import 'dart:io';

import 'package:bilicross/src/core/distribution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('发行通道判定', () {
    test('没有注入编译常量时按安装版处理', () {
      expect(channelFromDefine(''), ReleaseChannel.installed);
      expect(channelFromDefine('installed'), ReleaseChannel.installed);
      expect(channelFromDefine('   '), ReleaseChannel.installed);
    });

    test('注入 portable 时按便携版处理，大小写不敏感', () {
      expect(channelFromDefine('portable'), ReleaseChannel.portable);
      expect(channelFromDefine('Portable'), ReleaseChannel.portable);
      expect(channelFromDefine(' PORTABLE '), ReleaseChannel.portable);
    });

    test('未知取值不会被误判成便携版', () {
      expect(channelFromDefine('portable!'), ReleaseChannel.installed);
      expect(channelFromDefine('port'), ReleaseChannel.installed);
    });
  });

  group('数据目录策略', () {
    // 两个 CI 作业分别在 Linux 与 Windows 上跑测试，期望值要跟着平台分隔符走。
    final sep = Platform.pathSeparator;

    test('Windows 安装版放 %LOCALAPPDATA%\\BiliCross', () {
      final root = resolveDataRoot(
        channel: ReleaseChannel.installed,
        isWindows: true,
        environment: const {'LOCALAPPDATA': r'C:\Users\tester\AppData\Local'},
        systemSupportDirectory: Directory(r'C:\Users\tester\AppData\Roaming\app'),
      );
      expect(root.path, '${r'C:\Users\tester\AppData\Local'}${sep}BiliCross');
    });

    test('Windows 安装版拿不到 LOCALAPPDATA 时退回系统支持目录', () {
      final root = resolveDataRoot(
        channel: ReleaseChannel.installed,
        isWindows: true,
        environment: const {},
        systemSupportDirectory: Directory(r'C:\Users\tester\AppData\Roaming\app'),
      );
      expect(root.path.contains('BiliCross'), isTrue);
      expect(root.path.startsWith(r'C:\Users\tester\AppData\Roaming\app'), isTrue);
    });

    test('Windows 便携版放程序目录下的 data', () {
      // 路径按当前平台分隔符拼：CI 的 Linux 作业上反斜杠不是分隔符，
      // 直接写 r'D:\...' 会让 File.parent 退化成当前目录。
      final exe = 'D:${sep}BiliCross-Portable${sep}bilicross.exe';
      final root = resolveDataRoot(
        channel: ReleaseChannel.portable,
        isWindows: true,
        executablePath: exe,
        environment: const {'LOCALAPPDATA': r'C:\Users\tester\AppData\Local'},
        systemSupportDirectory: Directory(r'C:\Users\tester\AppData\Roaming\app'),
      );
      expect(root.path, 'D:${sep}BiliCross-Portable${sep}data');
    });

    test('非 Windows 平台保持旧位置，不受通道影响', () {
      final installed = resolveDataRoot(
        channel: ReleaseChannel.installed,
        isWindows: false,
        systemSupportDirectory: Directory('/data/user/0/app/files'),
      );
      final portable = resolveDataRoot(
        channel: ReleaseChannel.portable,
        isWindows: false,
        systemSupportDirectory: Directory('/data/user/0/app/files'),
      );
      expect(installed.path, '/data/user/0/app/files${sep}bilicross');
      expect(portable.path, installed.path);
    });

    test('旧目录候选按 bilicross、biliharbor 的顺序给出', () {
      final candidates = legacyDataRoots(Directory('/base'));
      expect(candidates.map((d) => d.path).toList(), [
        '/base${sep}bilicross',
        '/base${sep}biliharbor',
      ]);
    });
  });

  group('老数据迁移', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('bilicross_dist_');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('新目录不存在而旧目录存在时整体搬过去', () async {
      final legacy = Directory('${temp.path}${Platform.pathSeparator}legacy');
      legacy.createSync(recursive: true);
      File('${legacy.path}${Platform.pathSeparator}settings.json')
          .writeAsStringSync('{"locale_code":"en-US"}');
      Directory('${legacy.path}${Platform.pathSeparator}nested').createSync();
      File('${legacy.path}${Platform.pathSeparator}nested${Platform.pathSeparator}tasks.json')
          .writeAsStringSync('[]');

      final target = Directory('${temp.path}${Platform.pathSeparator}target');
      final result = await migrateIfNeeded(
        target: target,
        legacyCandidates: [legacy],
      );

      expect(result.path, target.path);
      expect(File('${target.path}${Platform.pathSeparator}settings.json').readAsStringSync(),
          '{"locale_code":"en-US"}');
      expect(
        File('${target.path}${Platform.pathSeparator}nested${Platform.pathSeparator}tasks.json')
            .existsSync(),
        isTrue,
      );
      expect(legacy.existsSync(), isFalse, reason: '旧目录应已搬走');
    });

    test('新目录已存在时不动旧目录', () async {
      final legacy = Directory('${temp.path}${Platform.pathSeparator}legacy');
      legacy.createSync(recursive: true);
      File('${legacy.path}${Platform.pathSeparator}settings.json').writeAsStringSync('old');

      final target = Directory('${temp.path}${Platform.pathSeparator}target');
      target.createSync(recursive: true);
      File('${target.path}${Platform.pathSeparator}settings.json').writeAsStringSync('new');

      await migrateIfNeeded(target: target, legacyCandidates: [legacy]);

      expect(File('${target.path}${Platform.pathSeparator}settings.json').readAsStringSync(),
          'new');
      expect(legacy.existsSync(), isTrue);
    });

    test('没有旧目录时创建空目录', () async {
      final target = Directory('${temp.path}${Platform.pathSeparator}fresh');
      final result = await migrateIfNeeded(target: target, legacyCandidates: []);
      expect(result.existsSync(), isTrue);
    });

    test('旧目录候选里第一条不存在时继续找第二条', () async {
      final older = Directory('${temp.path}${Platform.pathSeparator}biliharbor');
      older.createSync(recursive: true);
      File('${older.path}${Platform.pathSeparator}credential.json').writeAsStringSync('{}');

      final missing = Directory('${temp.path}${Platform.pathSeparator}bilicross');
      final target = Directory('${temp.path}${Platform.pathSeparator}out');
      await migrateIfNeeded(target: target, legacyCandidates: [missing, older]);

      expect(
        File('${target.path}${Platform.pathSeparator}credential.json').existsSync(),
        isTrue,
      );
    });
  });

  group('便携版标记', () {
    test('标记文件放在程序目录旁边，不在数据目录里', () {
      final marker = portableMarkerFile(
        'D:/BiliCross-Portable/bilicross.exe',
      );
      expect(marker.path.contains(kPortableMarker), isTrue);
      expect(marker.parent.path.contains('BiliCross-Portable'), isTrue);
    });
  });
}
