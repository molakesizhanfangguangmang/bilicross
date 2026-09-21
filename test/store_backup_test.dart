import 'dart:io';

import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 备份轮转与「同一时间戳撞名」的用例。
///
/// 全部用例注入固定时钟（[Store.at] 的 `clock`），确定性地构造出同一微秒内
/// 连续写入的场景 —— 真实时钟基本撞不上，撞不上就测不出覆盖 / 修剪错删。
///
/// ⚠️ 本轮处于停止编译状态，这些用例**尚未执行**。
///
/// 只使用中性假数据，且写入 `Directory.systemTemp` 下的临时目录，不碰真实用户数据。
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

/// 备份目录里属于 [targetName] 的备份文件，按文件名升序。
List<File> _backupsOf(Directory backupDir, String targetName) {
  if (!backupDir.existsSync()) return <File>[];
  final prefix = '$targetName.';
  final files = backupDir
      .listSync()
      .whereType<File>()
      .where((file) =>
          file.uri.pathSegments.last.startsWith(prefix) &&
          file.uri.pathSegments.last.endsWith('.bak'))
      .toList();
  files.sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
  return files;
}

/// 从 `tasks.json.<时间戳>[-N].bak` 里取出撞名序号；没有 `-N` 就是 0。
int _suffixOf(File backup, String targetName) {
  var rest = backup.uri.pathSegments.last.substring(targetName.length + 1);
  if (rest.endsWith('.bak')) rest = rest.substring(0, rest.length - 4);
  final dash = rest.lastIndexOf('-');
  if (dash <= 0) return 0;
  return int.tryParse(rest.substring(dash + 1)) ?? 0;
}

List<String> _tempFilesIn(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .map((file) => file.uri.pathSegments.last)
    .where((name) => name.endsWith('.tmp'))
    .toList();

/// 2026-09-21 10:11:12.123456 UTC —— 所有撞名用例共用这个固定时刻。
final DateTime _fixed = DateTime.utc(2026, 9, 21, 10, 11, 12, 123, 456);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_store_backup');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('备份轮转上限', () {
    test('任务保存 5 次：4 份历史被修剪回 3 份，且删掉的是最旧的一份', () async {
      final store = Store.at(root, clock: () => _fixed);
      for (var index = 0; index < 5; index++) {
        await store.saveTasks(<DownloadTask>[_task('t$index')]);
      }
      final backups = _backupsOf(store.backupDir, 'tasks.json');
      expect(backups, hasLength(3), reason: '任务备份上限是 3 份');

      // 第 1 次保存时还没有正式文件可备份，之后每次产生一份。
      // 固定时钟下走向撞名分支，序号依次是 0（无后缀）、2、3、4 → 修剪掉最旧的 0。
      final suffixes = backups.map((file) => _suffixOf(file, 'tasks.json')).toList()
        ..sort();
      expect(suffixes, <int>[2, 3, 4],
          reason: '必须按「时间戳 + 数值序号」判定最旧；字典序会把 -10 排到 -2 前面');
    });

    test('凭据保存 12 次：11 份历史被修剪回 10 份', () async {
      final store = Store.at(root, clock: () => _fixed);
      for (var index = 0; index < 12; index++) {
        await store.saveCredentials(_credential);
      }
      final backups = _backupsOf(store.backupDir, 'credential.json');
      expect(backups, hasLength(10), reason: '凭据备份上限是 10 份');

      // 保留的应当是最新的 10 份（序号 2..11），最旧的 0 号被删。
      final suffixes = backups.map((file) => _suffixOf(file, 'credential.json')).toList()
        ..sort();
      expect(suffixes, <int>[2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
          reason: '修剪必须删最旧的那份；错删会丢掉较新的 -10 而留下最旧的 0 号');
    });
  });

  group('同一时间戳下的备份命名', () {
    test('同一微秒连续保存 4 次：产生 3 份名称互不相同的备份', () async {
      final store = Store.at(root, clock: () => _fixed);
      for (var index = 0; index < 4; index++) {
        await store.saveTasks(<DownloadTask>[_task('t$index')]);
      }
      final backups = _backupsOf(store.backupDir, 'tasks.json');
      expect(backups, hasLength(3));

      final names = backups.map((file) => file.uri.pathSegments.last).toList();
      expect(names.toSet(), hasLength(3), reason: '撞名必须递增后缀，不能互相覆盖');

      final suffixes = backups.map((file) => _suffixOf(file, 'tasks.json')).toList()
        ..sort();
      expect(suffixes, <int>[0, 2, 3]);
    });

    test('同一微秒的 3 份备份内容互不相同（后一份不会覆盖前一份）', () async {
      final store = Store.at(root, clock: () => _fixed);
      for (var index = 0; index < 4; index++) {
        await store.saveTasks(<DownloadTask>[_task('t$index')]);
      }
      final backups = _backupsOf(store.backupDir, 'tasks.json');
      expect(backups, hasLength(3));

      final contents =
          backups.map((file) => file.readAsStringSync()).toList();
      // 三次备份应当分别保存了覆盖前的 t0 / t1 / t2 三个不同快照。
      final merged = contents.join('\n');
      for (final id in <String>['t0', 't1', 't2']) {
        expect(merged, contains('title-$id'), reason: '$id 的快照没被留下来');
      }
      expect(contents.toSet(), hasLength(3), reason: '三份备份内容必须各不相同');
    });

    test('同一微秒连续保存后，正式文件是最后一次调用的快照', () async {
      final store = Store.at(root, clock: () => _fixed);
      for (var index = 0; index < 4; index++) {
        await store.saveTasks(<DownloadTask>[_task('t$index')]);
      }
      expect((await store.loadTasks()).single.id, 't3');
    });

    test('同一微秒连续保存全程不残留 .tmp', () async {
      final store = Store.at(root, clock: () => _fixed);
      for (var index = 0; index < 4; index++) {
        await store.saveTasks(<DownloadTask>[_task('t$index')]);
      }
      expect(_tempFilesIn(root), isEmpty);
      expect(_tempFilesIn(store.backupDir), isEmpty);
    });
  });

  group('真实时钟下的备份', () {
    test('连续保存 4 次产生 3 份名称互不相同的备份', () async {
      final store = Store.at(root);
      for (var index = 0; index < 4; index++) {
        await store.saveTasks(<DownloadTask>[_task('t$index')]);
      }
      final backups = _backupsOf(store.backupDir, 'tasks.json');
      expect(backups, hasLength(3));
      expect(
        backups.map((file) => file.uri.pathSegments.last).toSet(),
        hasLength(3),
      );
      expect(_tempFilesIn(root), isEmpty);
    });
  });
}
