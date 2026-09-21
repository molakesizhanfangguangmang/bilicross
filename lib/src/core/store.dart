import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'distribution.dart';
import 'models.dart';

class CredentialBundle {
  const CredentialBundle({this.cookie = const WebCookie.empty(), this.token});

  final WebCookie cookie;
  final AppToken? token;
}

/// 本地持久化：设置、凭据、任务。
///
/// 写入一律先写临时文件再替换，并在替换前留一份时间戳备份（凭据最多保留 10 份）。
///
/// **同一个目标文件的写入严格串行**（见 [_enqueue]）：并发调用不再争用同一个
/// `.tmp`，且落盘顺序与调用顺序一致 —— 后一次调用落盘的快照不会被先一次的覆盖。
/// 不同目标文件（settings / credential / tasks）各自排队、互不阻塞。
///
/// ⚠️ 替换**不是严格原子的**：Windows 上 rename 不能覆盖已存在文件，所以是
/// 「删正式文件 → rename」两步，两步之间正式文件短暂不存在。断电级原子替换
/// 留到接入平台层时处理（见 [_performWrite]）。
class Store {
  Store._(this.root, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// 仅测试用：直接注入数据目录，不走 [Store.open] 的 path_provider /
  /// [resolveDataRoot] / [migrateIfNeeded]，免得测试在 Windows 上绕过假目录、
  /// 读到真实用户数据（见 [Store.open] 的注释）。[clock] 同样是测试专用，
  /// 用来确定性地构造「同一微秒撞名」的场景。
  @visibleForTesting
  Store.at(Directory root, {DateTime Function()? clock}) : this._(root, clock: clock);

  final Directory root;

  /// 备份文件名用的时间源。生产环境恒为 [DateTime.now]，测试可注入固定时钟。
  /// 只用于构造备份时间戳，不参与任何其它业务时间。
  final DateTime Function() _clock;

  /// 每个目标文件一条串行链，键是规范化后的绝对路径。
  /// 同一文件的写入按调用顺序依次执行；不同文件各排各的。
  final Map<String, Future<void>> _tail = <String, Future<void>>{};

  /// 数据目录按发行通道决定（见 [resolveDataRoot]）：
  /// Windows 安装版在 `%LOCALAPPDATA%\BiliCross`，便携版在程序旁的 `data`，
  /// 其它平台仍是系统应用支持目录下的 `bilicross`（与旧版本一致）。
  /// 老版本 Windows 用户的数据会被整体搬过来，不会看起来像丢了账号。
  ///
  /// [isWindows] 只给测试用：真机不传。测试要隔离数据目录时必须显式传 false，
  /// 否则在 Windows 上会绕过假的 applicationSupportPath、读到真实用户数据，
  /// 让测试互相污染（CI 跑 Linux 时不会暴露这个问题）。
  static Future<Store> open({bool? isWindows}) async {
    final base = await getApplicationSupportDirectory();
    final systemSupport = Directory(base.path);
    final target = resolveDataRoot(
      isWindows: isWindows,
      systemSupportDirectory: systemSupport,
    );
    final root = await migrateIfNeeded(
      target: target,
      legacyCandidates: legacyDataRoots(systemSupport),
    );
    if (!root.existsSync()) {
      await root.create(recursive: true);
    }
    return Store._(root);
  }

  File get settingsFile => File('${root.path}${Platform.pathSeparator}settings.json');
  File get credentialFile => File('${root.path}${Platform.pathSeparator}credential.json');
  File get taskFile => File('${root.path}${Platform.pathSeparator}tasks.json');
  Directory get backupDir => Directory('${root.path}${Platform.pathSeparator}backup');

  Future<AppSettings> loadSettings() async {
    final json = await _readJson(settingsFile);
    if (json == null) return AppSettings();
    return AppSettings.fromJson(json);
  }

  Future<void> saveSettings(AppSettings settings) =>
      _writeAtomic(settingsFile, settings.toJson());

  Future<CredentialBundle> loadCredentials() async {
    final json = await _readJson(credentialFile);
    if (json == null) return const CredentialBundle();
    final tokenJson = json['app_token'];
    return CredentialBundle(
      cookie: WebCookie.fromJson((json['web_cookie'] as Map?)?.cast<String, dynamic>() ?? const {}),
      token: tokenJson is Map ? AppToken.fromJson(tokenJson.cast<String, dynamic>()) : null,
    );
  }

  Future<void> saveCredentials(CredentialBundle bundle) => _writeAtomic(
        credentialFile,
        {
          'web_cookie': bundle.cookie.toJson(),
          if (bundle.token != null) 'app_token': bundle.token!.toJson(),
        },
        keepBackups: 10,
      );

  Future<List<DownloadTask>> loadTasks() async {
    final json = await _readJson(taskFile);
    if (json == null) return [];
    final raw = json['tasks'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) => DownloadTask.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<void> saveTasks(List<DownloadTask> tasks) => _writeAtomic(
        taskFile,
        {'tasks': tasks.map((task) => task.toJson()).toList()},
        keepBackups: 3,
      );

  Future<Map<String, dynamic>?> _readJson(File file) async {
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } on FormatException {
      return null;
    }
  }

  /// 在**调用时**把 payload 编码成不可变字符串，然后把「写这个字符串」排进队列。
  ///
  /// 提前编码有两个作用：一是「本次调用落的就是本次调用时的快照」不再依赖
  /// 「payload 里的集合不会被原地改」这种约定；二是写盘阶段只碰字符串，
  /// 不再延迟读取任务对象或 payload 里的可变集合。
  Future<void> _writeAtomic(
    File file,
    Map<String, dynamic> payload, {
    int keepBackups = 0,
  }) {
    // 紧凑输出：读写两侧都不依赖缩进，带缩进只是白占体积。
    final contents = jsonEncode(payload);
    return _enqueue(
      file.absolute.path,
      () => _performWrite(file, contents, keepBackups: keepBackups),
    );
  }

  /// 把 [job] 排到 [key] 那条链的末尾，返回**本次操作真实的** Future：
  /// 成功就是成功、失败就是失败，调用方拿得到真实错误。
  Future<void> _enqueue(String key, Future<void> Function() job) {
    final previous = _tail[key] ?? Future<void>.value();
    final current = previous.then((_) => job());

    // 链尾另外存一份「永不 reject」的版本：一次失败之后，该文件的后续写入
    // 仍能接上，不会被一个坏掉的链尾永久堵死。
    // ⚠️ safeTail 只用来衔接后续任务，**绝不能**返回给调用方 —— 那会把
    //    真实失败伪装成成功。
    final safeTail = current.then<void>((_) {}, onError: (Object _) {});
    _tail[key] = safeTail;

    // 队列空了就删条目，别让 Map 随文件数一直长。
    // 只在当前链尾仍是自己时才删：否则说明已有新任务接上，不能删。
    // safeTail 永不 reject、回调也不抛，所以这个 Future 不会变成未处理异常。
    unawaited(
      safeTail.whenComplete(() {
        if (identical(_tail[key], safeTail)) _tail.remove(key);
      }),
    );

    return current;
  }

  /// 真正的写盘：写临时文件 →（可选）轮转备份 → 删正式文件 → 重命名。
  ///
  /// 失败时**不删**自己刚写的那份 `.tmp`：此时正式文件可能已经删掉了，
  /// `.tmp` 里是唯一一份完整的新数据，留着可以人工恢复；它从不被读取
  /// （[_readJson] 只读正式文件），下一次成功写入会直接覆盖它，不会累积。
  Future<void> _performWrite(
    File file,
    String contents, {
    int keepBackups = 0,
  }) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(contents, flush: true);
    if (keepBackups > 0 && await file.exists()) {
      await _rotateBackups(file, keepBackups);
    }
    if (await file.exists()) {
      await file.delete();
    }
    // ⚠️ 到这里为止不是严格原子替换：delete 与 rename 之间正式文件短暂不存在。
    // 此刻异常退出会丢掉正式文件本身，但 `.tmp`（完整新数据）与 `.bak`（旧数据）
    // 都还在，可人工恢复。
    await temp.rename(file.path);
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _six(int value) => value.toString().padLeft(6, '0');

  /// 备份文件名里的时间戳，**固定宽度**，字典序即时间序。
  ///
  /// ⚠️ 不能用 `toIso8601String()`：它的小数位宽度会随微秒是否为 0 在 3 位 / 6 位
  /// 之间变化，而下面按完整路径字典序排序取最旧 —— 宽度不一致会把同一秒内的顺序
  /// 搞乱，修剪时就会删错那一份。所以这里自己按固定宽度拼。
  String _stamp() {
    final utc = _clock().toUtc();
    return '${utc.year}${_two(utc.month)}${_two(utc.day)}'
        'T${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}'
        '.${_six(utc.millisecond * 1000 + utc.microsecond)}';
  }

  Future<void> _rotateBackups(File file, int keep) async {
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    final stamp = _stamp();
    final name = file.uri.pathSegments.last;
    final separator = Platform.pathSeparator;

    // 同一微秒撞名时递增后缀，避免 File.copy 覆盖掉中间那一版。
    // 正常时钟基本走不到，但注入固定时钟的测试会走到，这条分支必须留着。
    var candidate = '$name.$stamp.bak';
    var suffix = 1;
    while (await File('${backupDir.path}$separator$candidate').exists()) {
      suffix += 1;
      candidate = '$name.$stamp-$suffix.bak';
    }
    await file.copy('${backupDir.path}$separator$candidate');

    // 旧命名（秒级）与新命名（微秒级）都以 `$name.` 开头，因此都会被列出、
    // 一起计入 keep —— 无需迁移，旧备份照样参与修剪。
    final prefix = '$name.';
    final entries = await backupDir
        .list()
        .where((entity) => entity is File && entity.uri.pathSegments.last.startsWith(prefix))
        .cast<File>()
        .toList();
    entries.sort((a, b) {
      final left = _backupSortKey(a.uri.pathSegments.last, prefix);
      final right = _backupSortKey(b.uri.pathSegments.last, prefix);
      final byStamp = left.$1.compareTo(right.$1);
      return byStamp != 0 ? byStamp : left.$2.compareTo(right.$2);
    });
    while (entries.length > keep) {
      final oldest = entries.removeAt(0);
      await oldest.delete();
    }
  }

  /// 备份文件名的排序键：`(时间戳, 撞名序号)`。
  ///
  /// ⚠️ 不能直接对整个文件名做字典序：时间戳虽是定宽的，但撞名后缀 `-2`、`-10`
  /// **不是** —— 字典序会把 `-10` 排到 `-2` 前面，于是「取最旧」取到的是较新的那份。
  /// 这里把时间戳与序号拆开分别比：时间戳定宽（旧式秒级 15 位、新式微秒级 22 位）
  /// 所以字典序即时间序；序号按数值比。
  static (String, int) _backupSortKey(String fileName, String prefix) {
    var rest = fileName.substring(prefix.length);
    if (rest.endsWith('.bak')) {
      rest = rest.substring(0, rest.length - 4);
    }
    final dash = rest.lastIndexOf('-');
    if (dash > 0) {
      final suffix = int.tryParse(rest.substring(dash + 1));
      if (suffix != null) return (rest.substring(0, dash), suffix);
    }
    return (rest, 0);
  }
}
