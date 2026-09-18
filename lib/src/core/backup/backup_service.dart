import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'backup_codec.dart';
import 'backup_format.dart';

/// 恢复过程中对外汇报的进度点，便于界面显示，也方便测试注入故障。
enum BackupRestoreStage {
  /// 已生成回滚快照。
  rollbackSaved,

  /// 正在写凭据。
  credentialWritten,

  /// 正在写设置。
  settingsWritten,

  /// 正在写任务。
  tasksWritten,
}

/// 备份与恢复。
///
/// 只做三件事：把数据目录里的既有 JSON 采集出来加密成 `.bcbak`；
/// 校验并解析一份 `.bcbak`；**覆盖式**写回去（先打回滚快照，失败自动回滚）。
///
/// 数据格式沿用应用现有的 `credential.json` / `settings.json` / `tasks.json`，
/// 不做二次建模 —— 这样新旧版本能互相识别，安装版与便携版也能互相恢复。
/// 纯 Dart（只用 dart:io / dart:convert），可在临时目录里直接单测。
class BackupService {
  BackupService({
    required this.codec,
    required this.root,
    required this.appVersion,
    required this.platform,
    this.onStage,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final BackupCodec codec;

  /// 数据目录（安装版是 `%LOCALAPPDATA%\BiliCross`，便携版是程序旁的 `data`）。
  final Directory root;

  final String appVersion;

  /// `windows` / `android` / …：只作为来源标记写入头部，不影响能否恢复。
  final String platform;

  /// 测试用的故障注入点；正式运行传 null。
  final void Function(BackupRestoreStage stage)? onStage;

  final DateTime Function() _clock;

  static const String credentialFileName = 'credential.json';
  static const String settingsFileName = 'settings.json';
  static const String taskFileName = 'tasks.json';

  /// 回滚快照与历史备份放这里（既有 [Store.backupDir] 用的同一个目录）。
  static const String snapshotDirName = 'backup';

  /// 参与备份/恢复的文件，顺序即写入顺序。
  static const List<String> payloadFiles = <String>[
    credentialFileName,
    settingsFileName,
    taskFileName,
  ];

  File _file(String name) => File('${root.path}${Platform.pathSeparator}$name');

  Directory get snapshotRoot =>
      Directory('${root.path}${Platform.pathSeparator}$snapshotDirName');

  /// 采集当前状态。只收存在的文件；缺失的键在恢复时不会被清空。
  Map<String, dynamic> collectPayload() {
    final files = <String, dynamic>{};
    for (final name in payloadFiles) {
      final file = _file(name);
      if (!file.existsSync()) continue;
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) continue;
      files[name] = jsonDecode(text);
    }
    return <String, dynamic>{
      'schema': kBackupPayloadSchema,
      'exported_at': _clock().toUtc().toIso8601String(),
      'app_version': appVersion,
      'platform': platform,
      'files': files,
    };
  }

  /// 建议文件名，例如 `BiliCross-Backup-20260919.bcbak`。
  String suggestFileName([DateTime? now]) {
    final at = (now ?? _clock()).toLocal();
    final stamp = '${at.year.toString().padLeft(4, '0')}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}';
    return 'BiliCross-Backup-$stamp$kBackupExtension';
  }

  /// 导出：加密成 `.bcbak` 字节。内容只留在内存里，不写日志、不上传。
  Future<Uint8List> exportBytes({DateTime? now}) => codec.encode(
        payload: collectPayload(),
        appVersion: appVersion,
        platform: platform,
        createdAt: now ?? _clock(),
      );

  /// 只读头部：界面在问「是否覆盖」之前用它显示来源。
  BackupHeader inspect(Uint8List bytes) => codec.readHeader(bytes);

  /// 校验并解析：格式、认证标签、载荷 schema 全过才返回可恢复计划。
  Future<BackupRestorePlan> plan(Uint8List bytes) async {
    final payload = await codec.decode(bytes);
    final files = payload.data['files'];
    if (files is! Map) {
      throw BackupFormatException('备份里没有可恢复的数据段');
    }
    final entries = <String, Map<String, dynamic>>{};
    for (final name in payloadFiles) {
      final raw = files[name];
      if (raw == null) continue;
      if (raw is! Map) {
        throw BackupFormatException('备份里的 $name 结构不对');
      }
      entries[name] = Map<String, dynamic>.from(raw);
    }
    return BackupRestorePlan(header: payload.header, files: entries);
  }

  /// 覆盖式恢复：
  /// 1. 先把当前三个文件整体快照到 `<root>/backup/…`；
  /// 2. 逐个原子替换（先写 `.tmp`，再把旧文件挪走，最后改名就位）；
  /// 3. 任何一步失败 → 用快照把三个文件回滚回去，再抛出原错误。
  ///
  /// 不做合并：恢复后应用数据就是备份里的那份。
  Future<BackupRestoreOutcome> restore(BackupRestorePlan plan) async {
    root.createSync(recursive: true);
    final snapshot = Directory(
      '${snapshotRoot.path}${Platform.pathSeparator}'
      'rollback-${_fileStamp(_clock())}',
    );
    snapshot.createSync(recursive: true);
    final snapshotFiles = <String, File>{};
    for (final name in payloadFiles) {
      final source = _file(name);
      if (!source.existsSync()) continue;
      final copy = File('${snapshot.path}${Platform.pathSeparator}$name');
      source.copySync(copy.path);
      snapshotFiles[name] = copy;
    }
    onStage?.call(BackupRestoreStage.rollbackSaved);

    final written = <String>[];
    try {
      for (final name in payloadFiles) {
        final data = plan.files[name];
        if (data == null) continue;
        _writeAtomic(_file(name), JsonEncoder.withIndent('  ').convert(data));
        written.add(name);
        if (name == credentialFileName) {
          onStage?.call(BackupRestoreStage.credentialWritten);
        } else if (name == settingsFileName) {
          onStage?.call(BackupRestoreStage.settingsWritten);
        } else if (name == taskFileName) {
          onStage?.call(BackupRestoreStage.tasksWritten);
        }
      }
    } catch (error) {
      _rollback(snapshotFiles);
      throw BackupRestoreException(
        '恢复失败，已回滚到恢复前的状态：${error.runtimeType}',
      );
    }

    return BackupRestoreOutcome(
      header: plan.header,
      restoredFiles: written,
      snapshotPath: snapshot.path,
      pendingTaskPaths: _missingTaskPaths(plan),
    );
  }

  /// 备份里的任务若指向已不存在的路径，返回出来交给界面标记「需要用户处理」，不在这里崩溃。
  List<String> _missingTaskPaths(BackupRestorePlan plan) {
    final tasks = plan.files[taskFileName];
    if (tasks == null) return const <String>[];
    final raw = tasks['tasks'];
    if (raw is! List) return const <String>[];
    final missing = <String>[];
    for (final item in raw) {
      if (item is! Map) continue;
      for (final key in const <String>['dir', 'download_dir', 'save_dir']) {
        final dir = item[key];
        if (dir is String && dir.trim().isNotEmpty && !Directory(dir).existsSync()) {
          missing.add(dir);
        }
      }
    }
    return missing;
  }

  void _writeAtomic(File target, String content) {
    final tmp = File('${target.path}.tmp');
    tmp.writeAsStringSync(content, flush: true);
    if (target.existsSync()) {
      final previous = File('${target.path}.pre-restore');
      if (previous.existsSync()) previous.deleteSync();
      target.renameSync(previous.path);
    }
    tmp.renameSync(target.path);
    final previous = File('${target.path}.pre-restore');
    if (previous.existsSync()) previous.deleteSync();
  }

  void _rollback(Map<String, File> snapshotFiles) {
    for (final name in payloadFiles) {
      final target = _file(name);
      final copy = snapshotFiles[name];
      final tmp = File('${target.path}.tmp');
      final previous = File('${target.path}.pre-restore');
      if (tmp.existsSync()) tmp.deleteSync();
      if (previous.existsSync()) previous.deleteSync();
      if (copy != null) {
        copy.copySync(target.path);
      } else if (target.existsSync()) {
        // 恢复前本来就没有这个文件：回滚时把它删掉，保持「恢复前状态」。
        target.deleteSync();
      }
    }
  }

  String _fileStamp(DateTime at) {
    final t = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

/// 校验通过的恢复计划。
class BackupRestorePlan {
  const BackupRestorePlan({required this.header, required this.files});

  final BackupHeader header;

  /// 文件名 → 该文件要恢复成的 JSON 内容。
  final Map<String, Map<String, dynamic>> files;

  /// 来源描述，界面用来提示「这份备份来自哪、什么时候做的」。
  String describeSource() =>
      '${header.platform} / ${header.appVersion} / '
      '${header.createdAt.toLocal().toIso8601String()}';
}

/// 恢复结果。
class BackupRestoreOutcome {
  const BackupRestoreOutcome({
    required this.header,
    required this.restoredFiles,
    required this.snapshotPath,
    required this.pendingTaskPaths,
  });

  final BackupHeader header;
  final List<String> restoredFiles;

  /// 恢复前的自动回滚快照目录，出问题可以手拷贝回去。
  final String snapshotPath;

  /// 备份里指向已不存在路径的任务目录，交给界面标记。
  final List<String> pendingTaskPaths;
}

/// 恢复过程出错（已回滚）。
class BackupRestoreException implements Exception {
  BackupRestoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
