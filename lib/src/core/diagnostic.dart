import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'log_store.dart';

/// 诊断包的文件名。带本地日期与时间，同一天导出多次不会互相覆盖。
String suggestDiagnosticFileName(DateTime now) {
  final at = now.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'BiliCross-Diagnostic-${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}.zip';
}

/// 把一份 JSON 结构里的字符串值都过一遍 [LogStore.mask]。
///
/// 只挡凭据（Cookie、access_key、sign、授权码等），本机路径与文件名原样保留 ——
/// 诊断包贴公开 issue 时不会泄露账号，但会带上本机路径，这是刻意取舍。
dynamic maskJsonValue(dynamic value) {
  if (value is String) return LogStore.mask(value);
  if (value is List) return value.map(maskJsonValue).toList();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': maskJsonValue(entry.value),
    };
  }
  return value;
}

/// 把环境、任务快照与日志打包成一个 zip 字节流。
///
/// [environment] 与 [tasks] 都应是可 JSON 编码的结构；[logText] 是内存里的
/// 运行日志，[logFileText] 是可选的磁盘日志文件内容（verbose 打开时才有）。
Uint8List buildDiagnosticZip({
  required Map<String, dynamic> environment,
  required List<Map<String, dynamic>> tasks,
  required String logText,
  String? logFileText,
}) {
  final archive = Archive();
  archive.addFile(
    ArchiveFile.string(
      'environment.json',
      const JsonEncoder.withIndent('  ').convert(maskJsonValue(environment)),
    ),
  );
  archive.addFile(
    ArchiveFile.string(
      'tasks.json',
      const JsonEncoder.withIndent('  ').convert(maskJsonValue(<String, dynamic>{
        'tasks': tasks,
      })),
    ),
  );
  archive.addFile(ArchiveFile.string('logs.txt', LogStore.mask(logText)));
  if (logFileText != null) {
    archive.addFile(ArchiveFile.string('bilicross.log', LogStore.mask(logFileText)));
  }
  return ZipEncoder().encodeBytes(archive);
}
