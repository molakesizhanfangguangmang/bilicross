import 'dart:io';

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/downloader.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:bilicross/src/i18n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

/// `AppState.canRetryMerge` 的缓存行为：命中、失效，以及不该进缓存的分支。
/// 用例只用中性假数据与临时目录。
void main() {
  late Directory root;
  late Store store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_merge_ready');
    store = Store.at(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String pathOf(String name) => '${root.path}${Platform.pathSeparator}$name';

  /// 双轨任务：两条轨道的档位都非 0，才走「可合并」这条路。
  DownloadTask dualTrack(
    String id, {
    required String video,
    required String audio,
    TaskStage stage = TaskStage.failed,
  }) =>
      DownloadTask(
        id: id,
        title: 'title-$id',
        source: 'https://www.example.com/video/BV0000000001',
        infoId: 'BV0000000001',
        page: 1,
        cid: 100000001,
        outputPath: pathOf('$id.mp4'),
        engine: 'dart',
        channel: 'manifest',
        stage: stage,
        videoPath: video,
        audioPath: audio,
        videoQualityId: 80,
        audioQualityId: 30280,
      );

  File writeNonEmpty(String path, [String content = 'fragment']) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  AppState stateWith(List<DownloadTask> tasks) =>
      AppState.forTest(store: store, settings: AppSettings(), tasks: tasks);

  group('分片判定的三种情形', () {
    test('视频与音频都在且非空 → 可合并', () {
      final task = dualTrack(
        'both',
        video: pathOf('both.v.m4s'),
        audio: pathOf('both.a.m4s'),
      );
      writeNonEmpty(task.videoPath);
      writeNonEmpty(task.audioPath);

      expect(stateWith(<DownloadTask>[task]).canRetryMerge(task), isTrue);
    });

    test('音频是空文件 → 不可合并（不能只看存在性）', () {
      final task = dualTrack(
        'empty-audio',
        video: pathOf('e.v.m4s'),
        audio: pathOf('e.a.m4s'),
      );
      writeNonEmpty(task.videoPath);
      writeNonEmpty(task.audioPath, '');

      expect(stateWith(<DownloadTask>[task]).canRetryMerge(task), isFalse);
    });

    test('视频分片缺失 → 不可合并', () {
      final task = dualTrack(
        'no-video',
        video: pathOf('missing.v.m4s'),
        audio: pathOf('present.a.m4s'),
      );
      writeNonEmpty(task.audioPath);

      expect(stateWith(<DownloadTask>[task]).canRetryMerge(task), isFalse);
    });

    test('单轨任务 → 不可合并，即使磁盘上两个路径都真有文件', () {
      final task = dualTrack(
        'single',
        video: pathOf('s.v.m4s'),
        audio: pathOf('s.a.m4s'),
      );
      writeNonEmpty(task.videoPath);
      writeNonEmpty(task.audioPath);
      task.videoQualityId = 0;

      expect(task.singleTrack, isTrue);
      expect(stateWith(<DownloadTask>[task]).canRetryMerge(task), isFalse);
    });

    test('音频路径为空 → 不可合并', () {
      final task = dualTrack(
        'no-audio-path',
        video: pathOf('n.v.m4s'),
        audio: '',
      );
      writeNonEmpty(task.videoPath);

      expect(stateWith(<DownloadTask>[task]).canRetryMerge(task), isFalse);
    });
  });

  group('缓存命中与失效', () {
    test('判定被缓存：分片随后被删，仍返回缓存值（没有重新读盘）', () async {
      final task = dualTrack(
        'cached-true',
        video: pathOf('c.v.m4s'),
        audio: pathOf('c.a.m4s'),
      );
      final video = writeNonEmpty(task.videoPath);
      final audio = writeNonEmpty(task.audioPath);
      final state = stateWith(<DownloadTask>[task]);

      expect(state.canRetryMerge(task), isTrue, reason: '首次判定读盘，两分片都在');

      // 绕过 AppState 把分片从盘上拿掉，读不到盘才会返回旧值。
      video.deleteSync();
      audio.deleteSync();

      expect(state.canRetryMerge(task), isTrue, reason: '命中缓存，磁盘已变但缓存未失效');

      await state.cleanupResidue();
      expect(state.canRetryMerge(task), isFalse, reason: '失效后重算，分片已不在');
    });

    test('缓存为 false 时，后来补上的分片不会立刻改变结果', () async {
      // A 是观察对象（已完成，清理不会动它的文件）；B 只用来触发一次缓存失效。
      final taskA = dualTrack(
        'cached-false',
        video: pathOf('f.v.m4s'),
        audio: pathOf('f.a.m4s'),
        stage: TaskStage.done,
      );
      final taskB = dualTrack(
        'cached-false-trigger',
        video: pathOf('f-t.v.m4s'),
        audio: pathOf('f-t.a.m4s'),
      );
      final state = stateWith(<DownloadTask>[taskA, taskB]);

      expect(state.canRetryMerge(taskA), isFalse, reason: '首次判定：分片还没落盘');

      writeNonEmpty(taskA.videoPath);
      writeNonEmpty(taskA.audioPath);

      expect(state.canRetryMerge(taskA), isFalse, reason: '仍是缓存里的 false，失效由显式调用控制');

      await state.cleanupTask(taskB.id);
      expect(state.canRetryMerge(taskA), isTrue, reason: '失效后重算：分片已齐');
    });

    test('失效由任务文件变化触发：清理残留后，已完成任务的缓存一并失效', () async {
      final taskA = dualTrack(
        'A',
        video: pathOf('A.v.m4s'),
        audio: pathOf('A.a.m4s'),
        stage: TaskStage.done,
      );
      final taskB = dualTrack(
        'B',
        video: pathOf('B.v.m4s'),
        audio: pathOf('B.a.m4s'),
      );
      writeNonEmpty(taskB.videoPath);
      final state = stateWith(<DownloadTask>[taskA, taskB]);

      expect(state.canRetryMerge(taskA), isFalse, reason: 'A 的分片此时不在盘上');

      writeNonEmpty(taskA.videoPath);
      writeNonEmpty(taskA.audioPath);
      expect(state.canRetryMerge(taskA), isFalse, reason: 'A 的分片补上了，但缓存还没失效');

      // B 触发一次文件清理 → 整张缓存失效 → A 按磁盘重算。
      await state.cleanupResidue();

      expect(state.canRetryMerge(taskA), isTrue);
      expect(taskA.stage, TaskStage.done, reason: '已完成任务的文件不在清理范围内');
    });

    test('缓存按任务 id 隔离，一个任务的判定不会串到另一个', () {
      final taskA = dualTrack(
        'iso-A',
        video: pathOf('iso-A.v.m4s'),
        audio: pathOf('iso-A.a.m4s'),
      );
      final taskB = dualTrack(
        'iso-B',
        video: pathOf('iso-B.v.m4s'),
        audio: pathOf('iso-B.a.m4s'),
      );
      final videoA = writeNonEmpty(taskA.videoPath);
      writeNonEmpty(taskA.audioPath);
      final state = stateWith(<DownloadTask>[taskA, taskB]);

      expect(state.canRetryMerge(taskA), isTrue);
      expect(state.canRetryMerge(taskB), isFalse);

      // 把两条任务的磁盘状态互换，各自仍读各自的缓存。
      videoA.deleteSync();
      File(taskA.audioPath).deleteSync();
      writeNonEmpty(taskB.videoPath);
      writeNonEmpty(taskB.audioPath);

      expect(state.canRetryMerge(taskA), isTrue);
      expect(state.canRetryMerge(taskB), isFalse);
    });
  });

  group('与 retryMerge 的前置判定一致', () {
    test('单轨任务：判定为 false，retryMerge 走同一条拒绝分支', () async {
      final task = dualTrack(
        'mux-single',
        video: pathOf('ms.v.m4s'),
        audio: pathOf('ms.a.m4s'),
      );
      writeNonEmpty(task.videoPath);
      writeNonEmpty(task.audioPath);
      task.videoQualityId = 0;
      final state = stateWith(<DownloadTask>[task]);

      expect(state.canRetryMerge(task), isFalse);

      await state.retryMerge(task.id);

      expect(task.stage, TaskStage.failed, reason: '拒绝合并，阶段不动');
      expect(task.message, const AppLocalizationsZh().tr('msg.singleTrackNoMux'));
    });

    test('缺分片：判定为 false，retryMerge 走同一条拒绝分支', () async {
      final task = dualTrack(
        'mux-missing',
        video: pathOf('mm.v.m4s'),
        audio: pathOf('mm.a.m4s'),
      );
      writeNonEmpty(task.videoPath);
      writeNonEmpty(task.audioPath, '');
      final state = stateWith(<DownloadTask>[task]);

      expect(state.canRetryMerge(task), isFalse);

      await state.retryMerge(task.id);

      expect(task.stage, TaskStage.failed, reason: '拒绝合并，阶段不动');
      expect(task.message, const AppLocalizationsZh().tr('msg.missingFragments'));
    });

    test('两分片齐：判定为 true，与 retryMerge 的前置条件一致', () {
      final task = dualTrack(
        'mux-ready',
        video: pathOf('mr.v.m4s'),
        audio: pathOf('mr.a.m4s'),
      );
      writeNonEmpty(task.videoPath);
      writeNonEmpty(task.audioPath);
      final state = stateWith(<DownloadTask>[task]);

      // 照 retryMerge 的准入条件独立算一遍做对照。
      final passesRetryMergeGuard = !task.singleTrack &&
          hasUsableFile(task.videoPath) &&
          hasUsableFile(task.audioPath);

      expect(state.canRetryMerge(task), isTrue);
      expect(state.canRetryMerge(task), passesRetryMergeGuard);
    });
  });
}
