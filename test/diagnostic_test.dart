import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:bilicross/src/core/diagnostic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('诊断包 zip 内是环境、任务与日志，凭据已被掩码', () {
    final bytes = buildDiagnosticZip(
      environment: <String, dynamic>{
        'cookie': 'SESSDATA=secret-value; bili_jct=csrf',
        'download_dir': r'C:\Users\someone\Downloads',
      },
      tasks: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 't1',
          'title': '示例',
          'source': 'https://www.bilibili.com/video/BV1',
        },
      ],
      logText: '12:00:00.000 [下载] 开始 SESSDATA=abc',
      logFileText: '12:00:01.000 [下载] access_key=xyz',
    );

    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files.map((f) => f.name), containsAll(<String>[
      'environment.json',
      'tasks.json',
      'logs.txt',
      'bilicross.log',
    ]));

    final envFile = archive.find('environment.json')!;
    final env = jsonDecode(utf8.decode(envFile.content)) as Map<String, dynamic>;
    // 凭据值被掩码，路径原样保留。
    expect('${env['cookie']}', isNot(contains('secret-value')));
    expect(env['download_dir'], r'C:\Users\someone\Downloads');

    final logFile = archive.find('bilicross.log')!;
    expect(utf8.decode(logFile.content), contains('access_key=***'));
  });

  test('文件名带本地日期时间，两次调用不重名', () {
    final first = suggestDiagnosticFileName(DateTime(2026, 9, 26, 10, 20, 30));
    final second = suggestDiagnosticFileName(DateTime(2026, 9, 26, 10, 20, 31));
    expect(first, startsWith('BiliCross-Diagnostic-20260926-'));
    expect(first, isNot(second));
    expect(first, endsWith('.zip'));
  });

  test('maskJsonValue 递归掩码，但不动非字符串', () {
    final masked = maskJsonValue(<String, dynamic>{
      'nested': <String, dynamic>{
        'cookie': 'SESSDATA=abc',
        'count': 3,
      },
    });
    final map = masked as Map<String, dynamic>;
    final nested = map['nested'] as Map<String, dynamic>;
    expect(nested['cookie'], isNot(contains('abc')));
    expect(nested['count'], 3);
  });
}
