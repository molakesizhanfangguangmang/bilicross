import 'dart:io';

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:bilicross/src/ui/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务页的行列表与计数都按缓存走，这里验证缓存随结构变化失效：
/// 增删任务、任务换栏、切栏之后，行与计数都要跟着变，不能停在旧数据上。
void main() {
  late Directory root;
  late AppState state;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_tasks_page');
    state = AppState.forTest(
      store: Store.at(root),
      settings: AppSettings(downloadDir: root.path),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  DownloadTask task(String id, TaskStage stage) => DownloadTask(
        id: id,
        title: 'title-$id',
        source: 'https://www.example.com/video/BV0000000001',
        infoId: 'BV0000000001',
        page: 1,
        cid: 1,
        outputPath: '${root.path}${Platform.pathSeparator}$id.mp4',
        engine: 'dart',
        channel: 'manifest',
        stage: stage,
      );

  /// 重 pump 一遍，与通知驱动的重建走同一条路径（缓存存在 State 里）。
  Future<void> render(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: TasksPage(state: state)));
    await tester.pump();
  }

  testWidgets('新增任务后出现新行', (tester) async {
    state.tasks.add(task('a', TaskStage.pending));
    await render(tester);
    expect(find.text('title-a'), findsOneWidget);

    state.tasks.insert(0, task('b', TaskStage.pending));
    await render(tester);
    expect(find.text('title-b'), findsOneWidget);
    expect(find.text('title-a'), findsOneWidget);
  });

  testWidgets('删除任务后行消失，栏计数同步', (tester) async {
    state.tasks.addAll(<DownloadTask>[
      task('a', TaskStage.pending),
      task('b', TaskStage.pending),
    ]);
    await render(tester);
    expect(find.text('等待下载 (2)'), findsOneWidget);

    state.tasks.removeWhere((item) => item.id == 'a');
    await render(tester);
    expect(find.text('title-a'), findsNothing);
    expect(find.text('title-b'), findsOneWidget);
    expect(find.text('等待下载 (1)'), findsOneWidget);
  });

  testWidgets('任务换栏后不再留在原栏', (tester) async {
    final item = task('a', TaskStage.pending);
    state.tasks.add(item);
    await render(tester);
    expect(find.text('title-a'), findsOneWidget);
    expect(find.text('下载中 (0)'), findsOneWidget);

    item.stage = TaskStage.downloading;
    await render(tester);
    expect(find.text('title-a'), findsNothing, reason: '等待栏不该还留着它');
    expect(find.text('下载中 (1)'), findsOneWidget);
  });

  testWidgets('切栏显示对应栏的行', (tester) async {
    state.tasks.addAll(<DownloadTask>[
      task('a', TaskStage.pending),
      task('b', TaskStage.done),
    ]);
    await render(tester);
    expect(find.text('title-b'), findsNothing);
    expect(find.text('已下载 (1)'), findsOneWidget);

    await tester.tap(find.text('已下载 (1)'));
    await tester.pump();

    expect(find.text('title-b'), findsOneWidget);
    expect(find.text('title-a'), findsNothing);
  });

  testWidgets('列表为空时显示空态', (tester) async {
    await render(tester);
    expect(find.text('暂无任务'), findsOneWidget);
  });
}
