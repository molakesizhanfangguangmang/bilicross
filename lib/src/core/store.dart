import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class CredentialBundle {
  const CredentialBundle({this.cookie = const WebCookie.empty(), this.token});

  final WebCookie cookie;
  final AppToken? token;
}

/// 本地持久化：设置、凭据、任务。
///
/// 写入一律先写临时文件再替换，并在替换前留一份时间戳备份（凭据最多保留 10 份）。
/// Windows 上 rename 不能覆盖已存在文件，所以替换分两步，窗口极小但非严格原子；
/// 真正的原子替换与系统级安全存储留到接入平台层时处理。
class Store {
  Store._(this.root);

  final Directory root;

  static Future<Store> open() async {
    final base = await getApplicationSupportDirectory();
    final root = Directory('${base.path}${Platform.pathSeparator}biliharbor');
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

  Future<void> _writeAtomic(
    File file,
    Map<String, dynamic> payload, {
    int keepBackups = 0,
  }) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(const JsonEncoder.withIndent('  ').convert(payload), flush: true);
    if (keepBackups > 0 && await file.exists()) {
      await _rotateBackups(file, keepBackups);
    }
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
  }

  Future<void> _rotateBackups(File file, int keep) async {
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final name = file.uri.pathSegments.last;
    await file.copy('${backupDir.path}${Platform.pathSeparator}$name.$stamp.bak');
    final prefix = '$name.';
    final entries = await backupDir
        .list()
        .where((entity) => entity is File && entity.uri.pathSegments.last.startsWith(prefix))
        .cast<File>()
        .toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    while (entries.length > keep) {
      final oldest = entries.removeAt(0);
      await oldest.delete();
    }
  }
}
