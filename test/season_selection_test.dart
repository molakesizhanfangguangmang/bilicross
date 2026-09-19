import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/season_selection.dart';
import 'package:flutter_test/flutter_test.dart';

SeasonEpisode _episode(int page, String title) => SeasonEpisode(
      bvid: 'BV00000000$page',
      aid: page,
      cid: page * 100,
      title: title,
      durationSec: 300,
      page: page,
    );

/// 两段清单：第一段 3 集（序号 1~3），第二段 2 集（序号 4~5）。
SeasonManifest _manifest() => SeasonManifest(
      seasonId: 3144260,
      title: '测试合集',
      owner: 'tester',
      cover: '',
      sections: <SeasonSection>[
        SeasonSection(
          id: 1,
          title: '第一段',
          episodes: <SeasonEpisode>[
            _episode(1, '第一讲'),
            _episode(2, '第二讲'),
            _episode(3, '第三讲'),
          ],
        ),
        SeasonSection(
          id: 2,
          title: '第二段',
          episodes: <SeasonEpisode>[
            _episode(4, '第四讲'),
            _episode(5, '第五讲'),
          ],
        ),
      ],
    );

void main() {
  group('单集勾选', () {
    test('勾上后数量变化且能查到自己，再勾取消', () {
      final selection = SeasonSelection();
      expect(selection.count, 0);
      expect(selection.isEmpty, isTrue);

      selection.toggleEpisode(2);
      expect(selection.count, 1);
      expect(selection.contains(2), isTrue);
      expect(selection.isEmpty, isFalse);

      selection.toggleEpisode(2);
      expect(selection.count, 0);
      expect(selection.contains(2), isFalse);
    });

    test('pages 是只读视图，外部改不动内部状态', () {
      final selection = SeasonSelection()..toggleEpisode(1);
      // Set.unmodifiable 返回只读视图：写入直接抛错，而不是静默丢掉。
      expect(() => selection.pages.add(99), throwsUnsupportedError);
      expect(selection.count, 1);
      expect(selection.contains(99), isFalse);
    });
  });

  group('段勾选', () {
    test('勾段 = 整段勾上；再勾 = 整段取消', () {
      final manifest = _manifest();
      final selection = SeasonSelection();
      final first = manifest.sections.first;

      selection.toggleSection(first);
      expect(selection.count, 3);
      expect(selection.allOf(first), isTrue);

      selection.toggleSection(first);
      expect(selection.count, 0);
      expect(selection.allOf(first), isFalse);
    });

    test('段内部分勾中时是半勾态（非全勾、非全不勾）', () {
      final manifest = _manifest();
      final selection = SeasonSelection()..toggleEpisode(1);

      expect(selection.allOf(manifest.sections.first), isFalse);
      expect(selection.anyOf(manifest.sections.first), isTrue);
    });

    test('段全不勾时照样能手勾单个集', () {
      final manifest = _manifest();
      final selection = SeasonSelection();
      expect(selection.allOf(manifest.sections.first), isFalse);

      selection.toggleEpisode(3);
      expect(selection.contains(3), isTrue);
      expect(selection.count, 1);
    });

    test('只影响被操作的段，另一段不受影响', () {
      final manifest = _manifest();
      final selection = SeasonSelection()..toggleSection(manifest.sections[1]);
      expect(selection.count, 2);
      expect(selection.contains(4), isTrue);
      expect(selection.contains(5), isTrue);
      expect(selection.contains(1), isFalse);
    });
  });

  group('合集全选', () {
    test('全选后数量等于总集数，再点清空', () {
      final manifest = _manifest();
      final selection = SeasonSelection();

      selection.toggleManifest(manifest);
      expect(selection.count, manifest.totalEpisodes);
      expect(selection.count, 5);
      expect(selection.allOfManifest(manifest), isTrue);

      selection.toggleManifest(manifest);
      expect(selection.count, 0);
      expect(selection.allOfManifest(manifest), isFalse);
    });

    test('手工勾满全部集后 allOfManifest 为真', () {
      final manifest = _manifest();
      final selection = SeasonSelection();
      for (final episode in manifest.allEpisodes) {
        selection.toggleEpisode(episode.page);
      }
      expect(selection.allOfManifest(manifest), isTrue);
    });
  });

  group('连续操作', () {
    test('连续勾选的结果是累积的，不会丢', () {
      final selection = SeasonSelection();
      for (var page = 1; page <= 5; page++) {
        selection.toggleEpisode(page);
      }
      expect(selection.count, 5);

      for (var page = 2; page <= 4; page += 2) {
        selection.toggleEpisode(page);
      }
      expect(selection.pages, <int>{1, 3, 5});
    });

    test('交替勾段与勾集不会互相覆盖', () {
      final manifest = _manifest();
      final selection = SeasonSelection();
      selection.toggleSection(manifest.sections[0]);
      selection.toggleEpisode(4);
      selection.toggleSection(manifest.sections[1]);
      expect(selection.pages, <int>{1, 2, 3, 4, 5});

      selection.toggleEpisode(1);
      expect(selection.pages, <int>{2, 3, 4, 5});
    });

    test('clear 清空', () {
      final selection = SeasonSelection()..toggleEpisode(1);
      selection.clear();
      expect(selection.isEmpty, isTrue);
    });
  });
}
