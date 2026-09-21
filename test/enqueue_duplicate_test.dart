import 'dart:io';

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一次入队的结果：计数 + 新任务的文件名与标题（没登记时为空串）。
typedef _Outcome = ({
  int enqueued,
  int skipped,
  int renamed,
  String name,
  String title,
});

/// 同名目标的三种处理模式：合集入队与多 P 入队必须给出一致的落点判定。
/// 两条路共用 `AppState._resolveDuplicatePath`，这里按模式对拍。
///
/// 两边目录不同（合集落子目录、多 P 落下载目录），所以对拍的是**文件名**：
/// 这里把两边的 stem 构造成同一个值，文件名一致即判定一致。
void main() {
  late Directory root;
  late Store store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_enqueue');
    store = Store.at(root);
  });

  tearDown(() async {
    // 入队触发的落盘是不等待的，删目录时它可能还在写（Windows 会报「目录不是空的」）。
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!root.existsSync()) return;
      try {
        root.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  });

  final sep = Platform.pathSeparator;
  String downloads() => '${root.path}${sep}downloads';

  /// 两边都做成这个 stem：合集是 `_pad2(page) + 标题`，多 P 直接用标题。
  const stem = '01 讲稿';

  const video = MediaStream(
    id: 80,
    label: '1080P',
    codecs: 'avc1',
    bandwidth: 1,
    url: 'https://www.example.com/v.m4s',
    height: 1080,
  );
  const audio = MediaStream(
    id: 30280,
    label: '192K',
    codecs: 'mp4a',
    bandwidth: 1,
    url: 'https://www.example.com/a.m4s',
  );

  DownloadTask occupied(String path) => DownloadTask(
        id: 'occupied',
        title: 'occupied',
        source: 'https://www.example.com/video/BV0000000009',
        infoId: 'BV0000000009',
        page: 1,
        cid: 1,
        outputPath: path,
        engine: 'dart',
        channel: 'manifest',
      );

  AppState stateWith(String mode, List<String> occupiedPaths) {
    final state = AppState.forTest(
      store: store,
      settings: AppSettings(downloadDir: downloads(), duplicateMode: mode),
      tasks: <DownloadTask>[for (final path in occupiedPaths) occupied(path)],
    );
    state.seedPreflightForTest(<int, PreflightResult>{
      1: const PreflightResult(
        status: PreflightStatus.ok,
        video: video,
        audio: audio,
        cid: 111,
      ),
    });
    return state;
  }

  _Outcome read(AppState state, DuplicateBatchOutcome outcome) {
    final fresh = state.tasks.where((task) => task.id != 'occupied').toList();
    return (
      enqueued: outcome.enqueued,
      skipped: outcome.skipped,
      renamed: outcome.renamed,
      name: fresh.isEmpty ? '' : fresh.first.outputPath.split(sep).last,
      title: fresh.isEmpty ? '' : fresh.first.title,
    );
  }

  _Outcome viaEpisodes(String mode, List<String> occupiedPaths) {
    final state = stateWith(mode, occupiedPaths);
    return read(
      state,
      state.enqueueEpisodes(
        manifest: const SeasonManifest(
          seasonId: 1,
          title: '集合',
          owner: 'tester',
          cover: '',
          sections: <SeasonSection>[
            SeasonSection(
              id: 1,
              title: '第一段',
              episodes: <SeasonEpisode>[
                SeasonEpisode(
                  bvid: 'BV0000000001',
                  aid: 1,
                  cid: 111,
                  title: '讲稿',
                  durationSec: 300,
                  page: 1,
                ),
              ],
            ),
          ],
        ),
        selectedPages: const <int>{1},
        engine: 'dart',
      ),
    );
  }

  _Outcome viaPages(String mode, List<String> occupiedPaths) {
    const page = PlayPage(page: 1, cid: 111, part: '讲稿', durationSec: 300);
    final state = stateWith(mode, occupiedPaths);
    return read(
      state,
      state.enqueuePages(
        media: const ParsedMedia(
          info: VideoInfo(
            bvid: 'BV0000000001',
            aid: 1,
            title: stem,
            owner: 'tester',
            cover: '',
            durationSec: 300,
            pages: <PlayPage>[page],
          ),
          page: page,
          videos: <MediaStream>[video],
          audios: <MediaStream>[audio],
          durationSec: 300,
          channel: 'web',
          guestLimited: false,
        ),
        pages: const <int>{1},
        engine: 'dart',
      ),
    );
  }

  /// 占位任务占住的路径：从原名起，连续 [count] 个编号。
  List<String> conflictIn(String dir, [int count = 1]) => <String>[
        '$dir$sep$stem.mp4',
        for (var index = 1; index < count; index++) '$dir$sep$stem ($index).mp4',
      ];

  String episodesDir() => '${downloads()}$sep集合';

  group('三种模式下两条入队路径的落点一致', () {
    for (final mode in <String>[
      kDuplicateSkip,
      kDuplicateRename,
      kDuplicateOverwrite,
    ]) {
      test(mode, () {
        final episodes = viaEpisodes(mode, conflictIn(episodesDir()));
        final pages = viaPages(mode, conflictIn(downloads()));

        expect(episodes.enqueued, pages.enqueued);
        expect(episodes.skipped, pages.skipped);
        expect(episodes.renamed, pages.renamed);
        expect(episodes.name, pages.name, reason: '文件名（含编号）必须一致');
        expect(episodes.title, pages.title);
      });
    }
  });

  group('各模式的落点', () {
    test('skip：撞名不登记', () {
      final outcomes = <_Outcome>[
        viaEpisodes(kDuplicateSkip, conflictIn(episodesDir())),
        viaPages(kDuplicateSkip, conflictIn(downloads())),
      ];

      for (final outcome in outcomes) {
        expect(outcome.enqueued, 0);
        expect(outcome.skipped, 1);
        expect(outcome.renamed, 0);
      }
    });

    test('rename：编号挂在扩展名前，标题同步改成新名', () {
      final pages = viaPages(kDuplicateRename, conflictIn(downloads()));

      expect(pages.name, '$stem (1).mp4');
      expect(pages.title, '$stem (1)');
      expect(pages.renamed, 1);
      expect(pages.skipped, 0);
    });

    test('rename：连续撞名继续递增', () {
      final episodes = viaEpisodes(kDuplicateRename, conflictIn(episodesDir(), 3));

      expect(episodes.name, '$stem (3).mp4');
      expect(episodes.title, '$stem (3)');
      expect(episodes.renamed, 1);
    });

    test('overwrite：沿用原名登记', () {
      final pages = viaPages(kDuplicateOverwrite, conflictIn(downloads()));

      expect(pages.name, '$stem.mp4');
      expect(pages.title, stem);
      expect(pages.enqueued, 1);
      expect(pages.renamed, 0);
    });

    test('没撞名时原名登记，不计重命名', () {
      final pages = viaPages(kDuplicateRename, const <String>[]);

      expect(pages.name, '$stem.mp4');
      expect(pages.enqueued, 1);
      expect(pages.renamed, 0);
    });
  });
}
