import 'dart:io';

import 'package:biliharbor/src/core/downloader.dart';
import 'package:biliharbor/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('biliharbor_cleanup');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File write(String path, String content) {
    final file = File(path);
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  group('残留清理', () {
    test('分片命名覆盖 0..15', () {
      final paths = artifactPaths('/tmp/a.video.m4s');
      expect(paths.first, '/tmp/a.video.m4s');
      expect(paths, contains('/tmp/a.video.m4s.part'));
      expect(paths, contains('/tmp/a.video.m4s.part0'));
      expect(paths, contains('/tmp/a.video.m4s.part15'));
    });

    test('空路径不产生任何待删项', () {
      expect(artifactPaths(''), isEmpty);
    });

    test('成品、半截 .part 与全部分片都被删掉', () async {
      final target = '${dir.path}${Platform.pathSeparator}video.m4s';
      write(target, 'done');
      write('$target.part', 'partial');
      write('$target.part0', 'chunk0');
      write('$target.part3', 'chunk3');

      final removed = await removeArtifacts(target);

      expect(removed, 4);
      expect(File(target).existsSync(), isFalse);
      expect(File('$target.part').existsSync(), isFalse);
      expect(File('$target.part0').existsSync(), isFalse);
      expect(File('$target.part3').existsSync(), isFalse);
      expect(Directory(dir.path).listSync(), isEmpty);
    });

    test('只删目标自己，不碰同目录的其它文件', () async {
      final keep = write('${dir.path}${Platform.pathSeparator}keep.mp4', 'keep');
      final target = '${dir.path}${Platform.pathSeparator}video.m4s';
      write(target, 'done');

      final removed = await removeArtifacts(target);

      expect(removed, 1);
      expect(keep.existsSync(), isTrue);
    });

    test('文件都不存在时返回 0', () async {
      final removed = await removeArtifacts('${dir.path}${Platform.pathSeparator}nothing.m4s');
      expect(removed, 0);
    });
  });

  group('画质排序', () {
    test('8K 排在 HDR Vivid 之前，HDR Vivid 排在 4K 之前', () {
      expect(qualityRank(127), lessThan(qualityRank(129)));
      expect(qualityRank(129), lessThan(qualityRank(120)));
      expect(qualityRank(120), lessThan(qualityRank(116)));
      expect(qualityRank(112), lessThan(qualityRank(80)));
    });

    test('未登记档位排在所有登记档位之后', () {
      final lowest = kQualityRank.length - 1;
      expect(qualityRank(100000), greaterThan(lowest));
      expect(qualityRank(5), lowest);
    });

    test('档位表本身按从高到低排好，且包含 8K', () {
      for (var index = 1; index < kQualityRank.length; index++) {
        expect(
          qualityRank(kQualityRank[index - 1]),
          lessThan(qualityRank(kQualityRank[index])),
          reason: '第 $index 项顺序不对',
        );
      }
      expect(kQualityRank.first, 127);
      expect(qualityLabel(127), '8K');
      expect(qualityLabel(129), 'HDR Vivid');
      expect(qualityLabel(128), isNot('8K'));
    });
  });
}
