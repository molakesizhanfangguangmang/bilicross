import 'dart:io';

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/rebuild_stats.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:bilicross/src/i18n/app_localizations.dart';
import 'package:bilicross/src/i18n/app_localizations_en.dart';
import 'package:bilicross/src/i18n/app_localizations_zh.dart';
import 'package:bilicross/src/ui/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 重建统计只用来判断「页面有没有被无关通知反复重建」，这里守住两件事：
/// 计数语义（累加 / 取走即归零），以及页面确实接了统计。
void main() {
  setUp(() => RebuildStats.takeAndReset());
  tearDown(() => RebuildStats.takeAndReset());

  test('计数按页面累加，取走快照后归零', () {
    RebuildStats.tick(RebuildStats.tasks);
    RebuildStats.tick(RebuildStats.tasks);
    RebuildStats.tick(RebuildStats.account);

    final first = RebuildStats.takeAndReset();
    expect(first[RebuildStats.tasks], 2);
    expect(first[RebuildStats.account], 1);
    expect(first.containsKey(RebuildStats.download), isFalse, reason: '没画过的页面不该出现');
    expect(RebuildStats.takeAndReset(), isEmpty, reason: '取走后必须归零');
  });

  test('重建统计的文案键中英文都齐，缺了不会静默回落', () {
    const keys = <String>[
      'settings.rebuildStats',
      'settings.rebuildStatsHint',
      'settings.rebuildStatsLogged',
      'settings.rebuildStatsEmpty',
      'rebuild.download',
      'rebuild.tasks',
      'rebuild.account',
      'rebuild.settings',
      'rebuild.times',
    ];
    for (final l10n in <AppLocalizations>[
      const AppLocalizationsZh(),
      const AppLocalizationsEn(),
    ]) {
      for (final key in keys) {
        expect(l10n.values[key], isNotNull, reason: '${l10n.code} 缺 $key');
        expect(l10n.values[key], isNot(key));
      }
    }
  });

  testWidgets('任务页重建时留下计数', (tester) async {
    final root = Directory.systemTemp.createTempSync('bilicross_rebuild');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final state = AppState.forTest(
      store: Store.at(root),
      settings: AppSettings(downloadDir: root.path),
    );

    await tester.pumpWidget(MaterialApp(home: TasksPage(state: state)));
    await tester.pump();

    expect(RebuildStats.takeAndReset()[RebuildStats.tasks], greaterThan(0));
  });
}
