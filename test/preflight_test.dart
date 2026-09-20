import 'dart:async';

import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/preflight.dart';
import 'package:flutter_test/flutter_test.dart';

SeasonEpisode _episode(int page) => SeasonEpisode(
      bvid: 'BV00000000$page',
      aid: page,
      cid: page * 100,
      title: '第 $page 集',
      durationSec: 300,
      page: page,
    );

const MediaStream _video = MediaStream(
  id: 80,
  label: '1080P',
  codecs: 'avc1.640028',
  bandwidth: 1000000,
  url: 'https://cdn.example/v80.m4s',
);

const MediaStream _video720 = MediaStream(
  id: 64,
  label: '720P',
  codecs: 'avc1.64001f',
  bandwidth: 500000,
  url: 'https://cdn.example/v64.m4s',
);

const PreflightResult _ok = PreflightResult(
  status: PreflightStatus.ok,
  video: _video,
);

/// 缺档：有流可下，但最高只到 720P，没有用户要的 1080P。
const PreflightResult _fellBack = PreflightResult(
  status: PreflightStatus.missingQuality,
  video: _video720,
  videoOptions: <MediaStream>[_video720],
  message: '最高 720P',
);

/// 档位齐全的一集：1080P 与 720P 都有。
const PreflightResult _twoOptions = PreflightResult(
  status: PreflightStatus.ok,
  video: _video,
  videoOptions: <MediaStream>[_video, _video720],
);

void main() {
  group('PreflightResult', () {
    test('只有 ok 且拿到流才算可下', () {
      expect(_ok.downloadable, isTrue);
      expect(
        const PreflightResult(status: PreflightStatus.ok).downloadable,
        isFalse,
      );
      expect(
        const PreflightResult(status: PreflightStatus.missingQuality)
            .downloadable,
        isFalse,
      );
      expect(
        const PreflightResult(status: PreflightStatus.unavailable).downloadable,
        isFalse,
      );
      expect(
        const PreflightResult(status: PreflightStatus.riskControl).downloadable,
        isFalse,
      );
      expect(const PreflightResult.unknown().downloadable, isFalse);
    });

    test('缺档但确实有流：仍然可下（设计定案允许按实际最高档下）', () {
      expect(_fellBack.downloadable, isTrue);
      expect(_fellBack.qualityFellBack, isTrue);
      // 一个流都没有的「缺档」才是真的下不了。
      expect(
        const PreflightResult(status: PreflightStatus.missingQuality)
            .downloadable,
        isFalse,
      );
      expect(_ok.qualityFellBack, isFalse);
    });

    test('videoFor：没指定档位就用实际最高档', () {
      expect(_twoOptions.videoFor(null)?.id, 80);
      expect(_twoOptions.videoFor(0)?.id, 80);
      expect(_fellBack.videoFor(null)?.id, 64);
    });

    test('videoFor：指定了档位就用那一档', () {
      expect(_twoOptions.videoFor(64)?.id, 64);
      expect(_twoOptions.videoFor(80)?.id, 80);
    });

    test('videoFor：这一集没有那一档就回落到最高档，不报错', () {
      // 缺档集只有 720P，用户却指定 1080P —— 不该抛，直接给 720P。
      expect(_fellBack.videoFor(80)?.id, 64);
      expect(_twoOptions.videoFor(127)?.id, 80);
    });
  });

  group('预检调度', () {
    test('只查选中的集，未选中的保持 unknown', () async {
      final asked = <int>[];
      final runner = PreflightRunner(
        resolve: (episode) async {
          asked.add(episode.page);
          return _ok;
        },
        onChanged: () {},
      );

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2), _episode(3)],
        pages: <int>{1, 3},
        parallel: true,
      );

      expect(asked..sort(), <int>[1, 3]);
      expect(runner.of(1).downloadable, isTrue);
      expect(runner.of(3).downloadable, isTrue);
      expect(runner.of(2).status, PreflightStatus.unknown);
    });

    test('取消勾选会清掉该集的结果', () async {
      final runner = PreflightRunner(
        resolve: (_) async => _ok,
        onChanged: () {},
      );

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1, 2},
        parallel: true,
      );
      expect(runner.of(1).downloadable, isTrue);
      expect(runner.of(2).downloadable, isTrue);

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1},
        parallel: true,
      );
      expect(runner.of(1).downloadable, isTrue);
      expect(runner.of(2).status, PreflightStatus.unknown);
    });

    test('已有结果不重复请求（勾选来回切不浪费请求）', () async {
      final asked = <int>[];
      final runner = PreflightRunner(
        resolve: (episode) async {
          asked.add(episode.page);
          return _ok;
        },
        onChanged: () {},
      );

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1)],
        pages: <int>{1},
        parallel: true,
      );
      await runner.run(
        episodes: <SeasonEpisode>[_episode(1)],
        pages: <int>{1},
        parallel: true,
      );

      expect(asked, <int>[1]);
    });

    test('旧批次的结果不回写新批次', () async {
      final gates = <Completer<PreflightResult>>[];
      final runner = PreflightRunner(
        resolve: (_) {
          final gate = Completer<PreflightResult>();
          gates.add(gate);
          return gate.future;
        },
        onChanged: () {},
      );
      final episodes = <SeasonEpisode>[_episode(1)];

      final first = runner.run(
        episodes: episodes,
        pages: <int>{1},
        parallel: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 1);

      // 第二批（还是这一集）：上一批在跑项被作废，因此会重新查一次。
      final second = runner.run(
        episodes: episodes,
        pages: <int>{1},
        parallel: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2, reason: '作废旧批次后必须重查，否则这集永远没结果');

      // 先完成旧批次：结果必须被丢弃。
      gates[0].complete(
        const PreflightResult(
          status: PreflightStatus.unavailable,
          message: '旧批次',
        ),
      );
      await first;
      expect(runner.of(1).status, PreflightStatus.unknown);

      // 再完成新批次：这次才写进去。
      gates[1].complete(_ok);
      await second;
      expect(runner.of(1).downloadable, isTrue);
    });

    test('reset 作废在跑的批次，其结果不落地', () async {
      final gates = <Completer<PreflightResult>>[];
      final runner = PreflightRunner(
        resolve: (_) {
          final gate = Completer<PreflightResult>();
          gates.add(gate);
          return gate.future;
        },
        onChanged: () {},
      );

      final running = runner.run(
        episodes: <SeasonEpisode>[_episode(1)],
        pages: <int>{1},
        parallel: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(runner.busy, isTrue);

      runner.reset();
      expect(runner.busy, isFalse);

      gates[0].complete(_ok);
      await running;
      expect(runner.of(1).status, PreflightStatus.unknown);
    });

    test('readyCount 只数通过预检的集', () async {
      final runner = PreflightRunner(
        resolve: (episode) async => episode.page == 1
            ? _ok
            : const PreflightResult(status: PreflightStatus.unavailable),
        onChanged: () {},
      );

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1, 2},
        parallel: true,
      );

      expect(runner.readyCount(<int>{1, 2}), 1);
      expect(runner.readyCount(<int>{1}), 1);
      expect(runner.readyCount(<int>{2}), 0);
    });

    test('串行模式也会全部跑完', () async {
      final asked = <int>[];
      final runner = PreflightRunner(
        resolve: (episode) async {
          asked.add(episode.page);
          return _ok;
        },
        onChanged: () {},
      );

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1, 2},
        parallel: false,
      );

      expect(asked..sort(), <int>[1, 2]);
      expect(runner.busy, isFalse);
    });

    test('halt 停手但保留已有结果（风控后还能看到缺档）', () async {
      final gates = <Completer<PreflightResult>>[];
      final runner = PreflightRunner(
        resolve: (_) {
          final gate = Completer<PreflightResult>();
          gates.add(gate);
          return gate.future;
        },
        onChanged: () {},
      );

      final running = runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1, 2},
        parallel: true,
      );
      await Future<void>.delayed(Duration.zero);

      // 第 1 集先出结果，随后撞上风控 → 停手。
      gates[0].complete(
        const PreflightResult(
          status: PreflightStatus.missingQuality,
          message: '这集最高可用 1080P',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runner.of(1).status, PreflightStatus.missingQuality);

      runner.halt();
      expect(runner.busy, isFalse);

      // 在跑的那一集返回时被批次号挡掉，不落地；已有结果不受影响。
      gates[1].complete(_ok);
      await running;
      expect(runner.of(1).status, PreflightStatus.missingQuality);
      expect(runner.of(2).status, PreflightStatus.unknown);
    });

    test('halt 不重跑已有结果的集', () async {
      final asked = <int>[];
      final runner = PreflightRunner(
        resolve: (episode) async {
          asked.add(episode.page);
          return _ok;
        },
        onChanged: () {},
      );

      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1, 2},
        parallel: true,
      );
      expect(asked.length, 2);

      runner.halt();
      await runner.run(
        episodes: <SeasonEpisode>[_episode(1), _episode(2)],
        pages: <int>{1, 2},
        parallel: true,
      );

      expect(asked.length, 2, reason: '恢复后不该把查过的集再查一遍');
      expect(runner.of(1).downloadable, isTrue);
      expect(runner.of(2).downloadable, isTrue);
    });
  });
}
