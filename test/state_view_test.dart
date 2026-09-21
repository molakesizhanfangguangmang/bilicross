import 'dart:io';

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:bilicross/src/i18n/app_localizations.dart';
import 'package:bilicross/src/ui/account_page.dart';
import 'package:bilicross/src/ui/download_page.dart';
import 'package:bilicross/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通知边界的过滤行为。
///
/// `shellView` 只在快照（语言 / 品牌色 / 队列开关 / 风控标记）变化时通知；
/// `stableView` 吞掉任务字节进度、其余照常透传。
/// 两条都只关心「该不该通知」，不关心界面长什么样。
void main() {
  late Directory root;
  late AppState state;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_state_view');
    state = AppState.forTest(
      store: Store.at(root),
      settings: AppSettings(downloadDir: root.path),
    );
  });

  tearDown(() {
    // 触发过落盘的用例会留下 .tmp 与备份，句柄释放有延迟，删不掉就重试。
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!root.existsSync()) return;
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        sleep(const Duration(milliseconds: 50));
      }
    }
  });

  DownloadTask task(String id, TaskStage stage) => DownloadTask(
        id: id,
        title: 'title-$id',
        source: 'https://www.example.com/video/BV0000000001',
        infoId: 'BV0000000001',
        page: 1,
        cid: 100000001,
        outputPath: '${root.path}${Platform.pathSeparator}$id.mp4',
        engine: 'dart',
        channel: 'manifest',
        stage: stage,
      );

  group('外壳视图', () {
    test('与外壳无关的通知不透传', () {
      var count = 0;
      state.shellView.addListener(() => count++);

      state.showNotice('随便一句提示');
      state.tasks.add(task('a', TaskStage.pending));

      expect(count, 0, reason: '提示与任务列表都不在外壳的快照里');
    });

    test('语言变化透传一次，同值再设一次不透传', () async {
      var count = 0;
      state.shellView.addListener(() => count++);

      await state.setLocale(kLocaleEnUS);
      expect(count, 1, reason: 'locale 变了，MaterialApp 必须重建');

      await state.setLocale(kLocaleEnUS);
      expect(count, 1, reason: '值没变就不该再重建');
    });

    test('品牌色变化透传', () {
      var count = 0;
      state.shellView.addListener(() => count++);

      state.settings.themeId = 'indigo';
      // 借一次无关通知把「有东西变了」送到视图，值级过滤负责判断该不该往下传。
      state.showNotice('重新求值');

      expect(count, 1, reason: '主题色变了，ThemeData 必须重算');
    });

    test('ffmpeg 路径变化不算外壳变化', () async {
      var count = 0;
      state.shellView.addListener(() => count++);

      await state.refreshFfmpeg();

      expect(count, 0, reason: '外壳不显示 ffmpeg 路径');
    });
  });

  group('稳定视图', () {
    test('字节进度被吞掉，字段照写', () {
      final item = task('a', TaskStage.downloading);
      state.tasks.add(item);
      var count = 0;
      state.stableView.addListener(() => count++);

      state.pushProgressForTest(item, 1024, 2048);

      expect(count, 0, reason: '下载期每秒十次的进度不该重建不显示进度的页面');
      expect(item.receivedBytes, 1024, reason: '只是不通知，字段该更新还是更新');
      expect(item.totalBytes, 2048);
    });

    test('非进度的通知照常透传', () {
      var count = 0;
      state.stableView.addListener(() => count++);

      state.showNotice('提示');

      expect(count, 1, reason: '漏掉非进度通知会让页面停在旧数据上');
    });
  });

  testWidgets('订阅稳定视图的界面：进度不重建、其它通知才重建', (tester) async {
    final item = task('a', TaskStage.downloading);
    state.tasks.add(item);
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: state.stableView,
          builder: (context, _) {
            builds++;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final base = builds;

    state.pushProgressForTest(item, 512, 1024);
    await tester.pump();
    expect(builds, base, reason: '进度不该触发重建');

    state.showNotice('提示');
    await tester.pump();
    expect(builds, base + 1, reason: '非进度通知仍要重建');
  });

  testWidgets('不显示进度的页面都订阅了稳定视图', (tester) async {
    // 哪个页面订阅哪一路，本身就是约定：换成 AppState 会把进度一起收下，
    // 换成 shellView 又会漏掉（比如设置页要看的 ffmpeg 路径）。
    Finder subscribedTo(Listenable target) => find.byWidgetPredicate(
          (widget) =>
              widget is ListenableBuilder && identical(widget.listenable, target),
        );

    final pages = <Widget>[
      DownloadPage(state: state),
      AccountPage(state: state),
      SettingsPage(state: state, canSave: ValueNotifier<bool>(false)),
    ];
    for (final page in pages) {
      // 页面在外壳里是 Scaffold 的 body，自己不带 Material。
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: page)),
      );
      expect(
        subscribedTo(state.stableView),
        findsWidgets,
        reason: '${page.runtimeType} 该订阅 stableView',
      );
      expect(
        subscribedTo(state),
        findsNothing,
        reason: '${page.runtimeType} 不该整页订阅 AppState（会跟着进度重建）',
      );
    }
  });
}
