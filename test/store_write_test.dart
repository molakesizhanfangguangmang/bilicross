import 'dart:convert';
import 'dart:io';

import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全部用例只用中性假数据：不写真实账号、Cookie、Token，也不依赖本机任何目录。
///
/// ⚠️ 本轮处于停止编译状态，这些用例**尚未执行**。
DownloadTask _task(String id) => DownloadTask(
      id: id,
      title: 'title-$id',
      source: 'https://www.example.com/video/BV0000000001',
      infoId: 'BV0000000001',
      page: 1,
      cid: 100000001,
      outputPath: 'downloads/$id.mp4',
      engine: 'dart',
      channel: 'manifest',
    );

const CredentialBundle _credential = CredentialBundle(
  cookie: WebCookie(
    raw: 'SESSDATA=test-sess; bili_jct=test-jct; DedeUserID=100000001',
    sessData: 'test-sess',
    biliJct: 'test-jct',
    dedeUserId: '100000001',
  ),
);

/// 数据目录里残留的临时文件（正常完成后应当一个都没有）。
List<String> _tempFilesIn(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .map((file) => file.uri.pathSegments.last)
    .where((name) => name.endsWith('.tmp'))
    .toList();

void main() {
  late Directory root;
  late Store store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_store_write');
    // 直接注入临时目录，不走 path_provider，避免碰到真实用户数据目录。
    store = Store.at(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('同一目标文件的并发写入', () {
    test('两次 saveTasks 并发调用不抛异常', () async {
      await Future.wait(<Future<void>>[
        store.saveTasks(<DownloadTask>[_task('a')]),
        store.saveTasks(<DownloadTask>[_task('b')]),
      ]);
      expect((await store.loadTasks()).map((task) => task.id), <String>['b']);
    });

    test('多次快速并发保存后，落盘内容是最后一次调用的快照', () async {
      final futures = <Future<void>>[];
      for (var index = 0; index < 20; index++) {
        // 故意不 await：模拟调用点连续触发（按钮连点就会走到这里）。
        futures.add(store.saveTasks(<DownloadTask>[_task('t$index')]));
      }
      await Future.wait(futures);
      // 只留一条任务，所以"最后一个快照"应当就是最后的 t19。
      expect((await store.loadTasks()).map((task) => task.id), <String>['t19']);
    });

    test('每次调用都拿到属于自己那次操作的 Future（不被替换成永远成功的链尾）',
        () async {
      final first = store.saveTasks(<DownloadTask>[_task('first')]);
      final second = store.saveTasks(<DownloadTask>[_task('second')]);
      await first;
      await second;
      // 按调用顺序落盘，最终是第二次的快照。
      expect((await store.loadTasks()).single.id, 'second');
    });

    test('任务、凭据、设置各自排队，并发互不破坏', () async {
      await Future.wait(<Future<void>>[
        store.saveTasks(<DownloadTask>[_task('x'), _task('y')]),
        store.saveCredentials(_credential),
        store.saveSettings(AppSettings(downloadDir: 'downloads')),
      ]);
      expect((await store.loadTasks()).map((task) => task.id), <String>['x', 'y']);
      expect((await store.loadCredentials()).cookie.sessData, 'test-sess');
      expect((await store.loadSettings()).downloadDir, 'downloads');
    });

    test('并发保存结束后不残留临时文件', () async {
      await Future.wait(<Future<void>>[
        store.saveTasks(<DownloadTask>[_task('a')]),
        store.saveTasks(<DownloadTask>[_task('b')]),
        store.saveCredentials(_credential),
      ]);
      expect(_tempFilesIn(root), isEmpty);
    });
  });

  group('写入失败后的恢复', () {
    /// 在固定 `.tmp` 路径上放一个同名**目录**，让 `temp.writeAsString` 稳定失败。
    ///
    /// 不用"只读目录"制造失败：不同系统与执行权限下行为不一致。
    /// 这个目录由测试自己清理，不交给生产逻辑。
    Directory blockTempFile(File target) =>
        Directory('${target.path}.tmp')..createSync(recursive: true);

    test('单次写入失败后队列不被堵死，后续保存仍能成功', () async {
      final blocker = blockTempFile(store.taskFile);
      addTearDown(() {
        if (blocker.existsSync()) blocker.deleteSync(recursive: true);
      });

      await expectLater(
        store.saveTasks(<DownloadTask>[_task('will-fail')]),
        throwsA(isA<FileSystemException>()),
        reason: '失败必须如实传给调用方，不能换成永远成功的链尾',
      );

      blocker.deleteSync(recursive: true);
      await store.saveTasks(<DownloadTask>[_task('recovered')]);
      expect((await store.loadTasks()).map((task) => task.id), <String>['recovered']);
      expect(_tempFilesIn(root), isEmpty);
    });

    test('失败那次没人处理的 Future 不会让队列卡死', () async {
      final blocker = blockTempFile(store.taskFile);
      addTearDown(() {
        if (blocker.existsSync()) blocker.deleteSync(recursive: true);
      });

      // 模拟后台保存：不等它、也不在调用点捕获它的错误。
      store.saveTasks(<DownloadTask>[_task('ignored-failure')]).ignore();

      // probe 排在它后面。它会真的执行到写盘那一步并同样撞上 blocker ——
      // 这就证明前一次失败没有把这条链堵死。
      await expectLater(
        store.saveTasks(<DownloadTask>[_task('probe')]),
        throwsA(isA<FileSystemException>()),
      );

      blocker.deleteSync(recursive: true);
      await store.saveTasks(<DownloadTask>[_task('after')]);
      expect((await store.loadTasks()).map((task) => task.id), <String>['after']);
    });

    test('失败不留下正式文件的半截内容', () async {
      final blocker = blockTempFile(store.taskFile);
      addTearDown(() {
        if (blocker.existsSync()) blocker.deleteSync(recursive: true);
      });

      await expectLater(
        store.saveTasks(<DownloadTask>[_task('will-fail')]),
        throwsA(isA<FileSystemException>()),
      );
      // 正式文件压根没被创建过，读取应当回落成空列表而不是抛异常。
      expect(store.taskFile.existsSync(), isFalse);
      expect(await store.loadTasks(), isEmpty);
    });
  });

  group('JSON 读取兼容', () {
    test('旧版带缩进的 JSON 仍可读取', () async {
      store.taskFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'tasks': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'legacy', 'title': 'legacy'},
          ],
        }),
      );
      expect((await store.loadTasks()).single.id, 'legacy');
    });

    test('紧凑 JSON 也能读取', () async {
      store.taskFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'tasks': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'compact', 'title': 'compact'},
          ],
        }),
      );
      expect((await store.loadTasks()).single.id, 'compact');
    });

    test('新写入的 JSON 字段往返一致', () async {
      final tasks = <DownloadTask>[_task('round-trip')];
      await store.saveTasks(tasks);
      final loaded = await store.loadTasks();
      expect(loaded.single.toJson(), tasks.single.toJson());
    });

    test('损坏的 JSON 回落成空列表，不抛异常', () async {
      store.taskFile.writeAsStringSync('{ not json');
      expect(await store.loadTasks(), isEmpty);
    });
  });
}
