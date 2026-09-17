import 'dart:io';

import 'package:flutter/foundation.dart';

/// 一条日志。时间取本地时区；同一批写入的行共享同一个时间戳。
class LogEntry {
  const LogEntry({required this.at, required this.tag, required this.text});

  final DateTime at;
  final String tag;
  final String text;

  String get line => '${stamp(at)} [$tag] $text';

  static String stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }
}

/// 运行日志：内存环形缓冲 + 可选的追加文件。
///
/// 所有文本入库前都过一遍 [mask]，Cookie、access_key、sign、授权码这类凭据
/// 不会以原文进入内存日志，也不会写进日志文件。
class LogStore {
  LogStore._();

  static final LogStore instance = LogStore._();

  /// 内存里最多保留多少条，超出丢最旧的。
  static const int capacity = 600;

  /// 日志文件超过这个大小就轮换成 `.1` 再重开一份。
  static const int maxFileBytes = 256 * 1024;

  final List<LogEntry> _entries = <LogEntry>[];

  /// 条目变化计数。界面监听它重绘，不去监听 List 本身。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 详细日志：打开后记录请求地址、响应码这类细节，并把日志追加到文件。
  bool verbose = false;

  File? _file;
  int _fileBytes = 0;

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  String? get filePath => _file?.path;

  String get dump => _entries.map((entry) => entry.line).join('\n');

  /// 绑定日志目录。绑不上也不抛：没有文件，内存日志照常可用。
  Future<void> attach(Directory root) async {
    try {
      if (!root.existsSync()) {
        await root.create(recursive: true);
      }
      final file = File('${root.path}${Platform.pathSeparator}bilicross.log');
      _fileBytes = file.existsSync() ? await file.length() : 0;
      _file = file;
    } on FileSystemException {
      _file = null;
    }
  }

  /// 记一条。[detail] 为真的条目只在 [verbose] 打开时记录。
  void add(String tag, String text, {bool detail = false}) {
    if (detail && !verbose) return;
    final now = DateTime.now();
    final start = _entries.length;
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      _entries.add(LogEntry(at: now, tag: tag, text: mask(line)));
    }
    if (_entries.length == start) return;
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    revision.value++;
    if (verbose) _appendToFile(start);
  }

  void clear() {
    _entries.clear();
    revision.value++;
    final file = _file;
    if (file == null || !verbose) return;
    try {
      file.writeAsStringSync('');
      _fileBytes = 0;
    } on FileSystemException {
      _file = null;
    }
  }

  void _appendToFile(int start) {
    final file = _file;
    if (file == null) return;
    try {
      if (_fileBytes > maxFileBytes) {
        final rotated = File('${file.path}.1');
        if (rotated.existsSync()) rotated.deleteSync();
        file.renameSync(rotated.path);
        _fileBytes = 0;
      }
      final text = _entries.skip(start).map((entry) => entry.line).join('\n');
      if (text.isEmpty) return;
      file.writeAsStringSync('$text\n', mode: FileMode.append);
      _fileBytes += text.length + 1;
    } on FileSystemException {
      // 落盘失败就退回纯内存，不因为日志影响主流程。
      _file = null;
    }
  }

  /// 请求头整行掩码，连字段名一起抹掉。
  static final RegExp _cookieHeader =
      RegExp(r'(cookie|set-cookie)\s*:\s*[^\n]+', caseSensitive: false);

  /// 查询串里的凭据参数：保留键名，值换成 `***`。
  /// 用 `caseSensitive: false` 而不是 `(?i)`：Dart 的 RegExp 不支持内联标志。
  static final RegExp _secretPair = RegExp(
    r'\b(access_key|access_token|sign|refresh_token|auth_code|appsec'
    r'|app_secret|sessdata|bili_jct|dedeuserid|csrf)\b\s*[=:]\s*[^&\s;]+',
    caseSensitive: false,
  );

  static String mask(String input) {
    var text = input.replaceAllMapped(
      _cookieHeader,
      (match) => '${match.group(1)}: ***',
    );
    text = text.replaceAllMapped(
      _secretPair,
      (match) => '${match.group(1)}=***',
    );
    return text;
  }
}
