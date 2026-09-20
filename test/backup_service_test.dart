import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bilicross/src/core/backup/backup_codec.dart';
import 'package:bilicross/src/core/backup/backup_format.dart';
import 'package:bilicross/src/core/backup/backup_key_ring.dart';
import 'package:bilicross/src/core/backup/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全部用例只用公开测试密钥与中性假数据，不得出现真实账号或正式密钥。
BackupService _service(
  Directory root, {
  String platform = 'windows',
  void Function(BackupRestoreStage stage)? onStage,
}) => BackupService(
  codec: BackupCodec(keyRing: BackupKeyRing.testOnly()),
  root: root,
  appVersion: '1.0.6',
  platform: platform,
  onStage: onStage,
);

Map<String, dynamic> _credential() => <String, dynamic>{
  'cookie': 'SESSDATA=test-sess; bili_jct=test-jct; DedeUserID=100000001',
  'token': <String, dynamic>{'access_token': 'test-token'},
};

Map<String, dynamic> _settings() => <String, dynamic>{
  'locale_code': 'zh-CN',
  'download_dir': '/tmp/downloads',
  'ffmpeg_path': '',
};

List<dynamic> _tasks() => <dynamic>[
  <String, dynamic>{'id': 't1', 'title': 'test', 'dir': '/tmp/downloads'},
];

/// v2 头部里 `kdf_algorithm` 的偏移。
///
/// ⚠️ 必须按布局算，不能用 `indexOf` 猜 —— 值等于 1 的字节到处都是
/// （salt、时间戳里都有）。
int _kdfAlgorithmOffset(Uint8List b) {
  var o = kBackupMagic.length + 2 + 1; // magic + format_version + algorithm
  o += 1 + b[o]; // key_id（uint8 长度 + 内容）
  o += 8; // created_at_ms
  o += 2 + ((b[o] << 8) | b[o + 1]); // app_version（uint16 大端）
  o += 1 + b[o]; // platform
  o += 1 + b[o]; // payload_type
  return o;
}

void _writeJson(Directory root, String name, Object? value) {
  File('${root.path}${Platform.pathSeparator}$name')
      .writeAsStringSync(jsonEncode(value));
}

String _read(Directory root, String name) =>
    File('${root.path}${Platform.pathSeparator}$name').readAsStringSync();

/// 测试口令。长度必须 ≥ kBackupMinPassphraseLength。
const String _kPass = 'test-passphrase-1234';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_backup_');
    _writeJson(root, BackupService.credentialFileName, _credential());
    _writeJson(root, BackupService.settingsFileName, _settings());
    _writeJson(root, BackupService.taskFileName, <String, dynamic>{
      'tasks': _tasks(),
    });
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('导出', () {
    test('编出来的备份能解回同一份数据', () async {
      final service = _service(root);
      final bytes = await service.exportBytes(passphrase: _kPass);
      final plan = await service.plan(bytes, passphrase: _kPass);

      expect(
        plan.files[BackupService.credentialFileName]!['cookie'],
        contains('SESSDATA=test-sess'),
      );
      expect(
        plan.files[BackupService.settingsFileName]!['locale_code'],
        'zh-CN',
      );
      expect(
        (plan.files[BackupService.taskFileName]!['tasks'] as List).length,
        1,
      );
      expect(plan.header.appVersion, '1.0.6');
      expect(plan.header.platform, 'windows');
      expect(plan.header.payloadType, kBackupPayloadTypeFull);
    });

    test('建议文件名带日期与 .bcbak 扩展名', () {
      final service = _service(root);
      final name = service.suggestFileName(DateTime(2026, 9, 19));
      expect(name, 'BiliCross-Backup-20260919.bcbak');
    });

    test('文件里没有明文凭据', () async {
      final bytes = await _service(root).exportBytes(passphrase: _kPass);
      final text = String.fromCharCodes(bytes);
      expect(text.contains('test-sess'), isFalse);
      expect(text.contains('SESSDATA'), isFalse);
      expect(text.contains('locale_code'), isFalse);
    });

    test('缺失的文件不进备份', () async {
      File('${root.path}${Platform.pathSeparator}${BackupService.taskFileName}')
          .deleteSync();
      final plan = await _service(root).plan(
        await _service(root).exportBytes(passphrase: _kPass),
        passphrase: _kPass,
      );
      expect(plan.files.containsKey(BackupService.taskFileName), isFalse);
    });
  });

  group('恢复（覆盖式 + 回滚快照）', () {
    test('恢复会把当前数据替换成备份里的内容', () async {
      final service = _service(root);
      final bytes = await service.exportBytes(passphrase: _kPass);

      // 备份之后用户改了设置、清了凭据
      _writeJson(root, BackupService.credentialFileName, <String, dynamic>{});
      _writeJson(root, BackupService.settingsFileName, <String, dynamic>{
        'locale_code': 'en-US',
        'download_dir': '/changed',
      });

      final outcome = await service.restore(
        await service.plan(bytes, passphrase: _kPass),
      );

      expect(outcome.restoredFiles, contains(BackupService.settingsFileName));
      expect(
        jsonDecode(_read(root, BackupService.settingsFileName)),
        _settings(),
      );
      expect(
        jsonDecode(_read(root, BackupService.credentialFileName)),
        _credential(),
      );
    });

    test('恢复前会留下回滚快照，里面是恢复前的数据', () async {
      final service = _service(root);
      final bytes = await service.exportBytes(passphrase: _kPass);
      _writeJson(root, BackupService.settingsFileName, <String, dynamic>{
        'locale_code': 'en-US',
      });

      final outcome = await service.restore(
        await service.plan(bytes, passphrase: _kPass),
      );

      final snapshot = Directory(outcome.snapshotPath);
      expect(snapshot.existsSync(), isTrue);
      final before = jsonDecode(
        File(
          '${snapshot.path}${Platform.pathSeparator}'
          '${BackupService.settingsFileName}',
        ).readAsStringSync(),
      );
      expect(before['locale_code'], 'en-US', reason: '快照应是恢复前的状态');
    });

    test('恢复中途失败会回滚到恢复前，并抛出明确错误', () async {
      final service = _service(root);
      final bytes = await service.exportBytes(passphrase: _kPass);
      _writeJson(root, BackupService.settingsFileName, <String, dynamic>{
        'locale_code': 'en-US',
      });
      _writeJson(root, BackupService.credentialFileName, <String, dynamic>{
        'cookie': 'SESSDATA=before-restore',
      });

      final failing = _service(
        root,
        onStage: (stage) {
          if (stage == BackupRestoreStage.credentialWritten) {
            throw StateError('注入的写盘故障');
          }
        },
      );

      await expectLater(
        () async =>
            failing.restore(await service.plan(bytes, passphrase: _kPass)),
        throwsA(isA<BackupRestoreException>()),
      );

      expect(
        jsonDecode(_read(root, BackupService.credentialFileName))['cookie'],
        'SESSDATA=before-restore',
        reason: '失败后凭据必须是恢复前那一份',
      );
      expect(
        jsonDecode(_read(root, BackupService.settingsFileName))['locale_code'],
        'en-US',
        reason: '失败后设置必须是恢复前那一份',
      );
    });

    test('备份里没有的文件保持本地现状（不做合并也不清空）', () async {
      File('${root.path}${Platform.pathSeparator}${BackupService.taskFileName}')
          .deleteSync();
      final bytes = await _service(root).exportBytes(passphrase: _kPass);
      _writeJson(root, BackupService.taskFileName, <String, dynamic>{
        'tasks': <dynamic>[
          <String, dynamic>{'id': 'local-only'},
        ],
      });

      final service = _service(root);
      await service.restore(await service.plan(bytes, passphrase: _kPass));

      final tasks =
          jsonDecode(_read(root, BackupService.taskFileName))['tasks'] as List;
      expect(tasks.length, 1);
      expect(tasks.first['id'], 'local-only');
    });
  });

  group('跨平台互恢复与异常', () {
    test('安卓做的备份能在 Windows 上恢复', () async {
      final androidRoot = Directory.systemTemp.createTempSync(
        'bilicross_android_',
      );
      addTearDown(() {
        if (androidRoot.existsSync()) androidRoot.deleteSync(recursive: true);
      });
      _writeJson(androidRoot, BackupService.settingsFileName, _settings());
      final bytes = await _service(
        androidRoot,
        platform: 'android',
      ).exportBytes(passphrase: _kPass);

      final windowsService = _service(root);
      final outcome = await windowsService.restore(
        await windowsService.plan(bytes, passphrase: _kPass),
      );

      expect(outcome.header.platform, 'android');
      expect(
        jsonDecode(_read(root, BackupService.settingsFileName))['locale_code'],
        'zh-CN',
      );
    });

    test('Windows 做的备份能在安卓上恢复', () async {
      // 反方向也要验：备份的 platform 只是**来源标记**，不该影响能否恢复。
      final windowsRoot = Directory.systemTemp.createTempSync('bilicross_win_');
      addTearDown(() {
        if (windowsRoot.existsSync()) windowsRoot.deleteSync(recursive: true);
      });
      _writeJson(windowsRoot, BackupService.settingsFileName, _settings());
      final bytes = await _service(
        windowsRoot,
        platform: 'windows',
      ).exportBytes(passphrase: _kPass);

      final androidService = _service(root, platform: 'android');
      final outcome = await androidService.restore(
        await androidService.plan(bytes, passphrase: _kPass),
      );

      expect(outcome.header.platform, 'windows');
      expect(
        jsonDecode(_read(root, BackupService.settingsFileName))['locale_code'],
        'zh-CN',
      );
    });

    test('被改过的备份无法恢复', () async {
      final service = _service(root);
      final bytes = await service.exportBytes(passphrase: _kPass);
      bytes[bytes.length - 1] ^= 0x01;
      // ⚠️ 口令备份的认证失败抛的是 BackupPassphraseException ——
      // AEAD 分不清「口令错」和「文件被改」，只能按头部判断是不是口令备份，
      // 据此给更贴切的提示。老格式（v1）才抛 BackupAuthenticationException。
      await expectLater(
        () => service.plan(bytes, passphrase: _kPass),
        throwsA(isA<BackupPassphraseException>()),
      );
    });

    test('备份里的任务目录不存在时列出来，不抛异常', () async {
      _writeJson(root, BackupService.taskFileName, <String, dynamic>{
        'tasks': <dynamic>[
          <String, dynamic>{'id': 't1', 'dir': '/definitely/not/here/12345'},
        ],
      });
      final service = _service(root);
      final outcome = await service.restore(
        await service.plan(
          await service.exportBytes(passphrase: _kPass),
          passphrase: _kPass,
        ),
      );
      expect(outcome.pendingTaskPaths, contains('/definitely/not/here/12345'));
    });

    test('不是备份文件时给出格式错误', () async {
      final service = _service(root);
      await expectLater(
        () =>
            service.plan(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9])),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('inspect：界面读头部阶段就要拒掉坏文件', () {
    test('未知 KDF → inspect 直接抛 BackupFormatException，不用等口令', () async {
      final service = _service(root);
      final bytes = await service.exportBytes(passphrase: _kPass);
      bytes[_kdfAlgorithmOffset(bytes)] = 0x7f;

      // 界面流程是 inspect → 判断要不要问口令 → plan。能在 inspect 就失败，
      // 用户就不会白输一遍口令。
      expect(
        () => service.inspect(bytes),
        throwsA(isA<BackupFormatException>()),
      );
      await expectLater(
        () => service.plan(bytes),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('跨平台恢复：平台专属设置按目标平台重置', () {
    test('Windows 备份恢复到安卓：清掉平台专属字段，其余设置保留', () async {
      final winRoot = Directory.systemTemp.createTempSync('bilicross_win_');
      addTearDown(() {
        if (winRoot.existsSync()) winRoot.deleteSync(recursive: true);
      });
      _writeJson(winRoot, BackupService.settingsFileName, <String, dynamic>{
        'locale_code': 'zh-CN',
        'download_dir': r'C:\Users\someone\Downloads',
        'ffmpeg_path': r'C:\tools\ffmpeg.exe',
        'close_to_tray': true,
        'theme_id': 'ocean',
      });
      final bytes = await _service(
        winRoot,
        platform: 'windows',
      ).exportBytes(passphrase: _kPass);

      final android = _service(root, platform: 'android');
      final outcome = await android.restore(
        await android.plan(bytes, passphrase: _kPass),
      );

      final restored =
          jsonDecode(_read(root, BackupService.settingsFileName))
              as Map<String, dynamic>;
      expect(restored.containsKey('download_dir'), isFalse);
      expect(restored.containsKey('ffmpeg_path'), isFalse);
      expect(restored.containsKey('close_to_tray'), isFalse);
      expect(restored['locale_code'], 'zh-CN', reason: '非平台字段必须保留');
      expect(restored['theme_id'], 'ocean');
      expect(outcome.resetSettingKeys, <String>[
        'download_dir',
        'ffmpeg_path',
        'close_to_tray',
      ]);
    });

    test('同平台恢复不动平台专属字段', () async {
      final service = _service(root); // windows → windows
      final outcome = await service.restore(
        await service.plan(
          await service.exportBytes(passphrase: _kPass),
          passphrase: _kPass,
        ),
      );
      final restored =
          jsonDecode(_read(root, BackupService.settingsFileName))
              as Map<String, dynamic>;
      expect(restored['download_dir'], '/tmp/downloads');
      expect(outcome.resetSettingKeys, isEmpty);
    });

    test('filterSettingsForPlatform：同平台原样返回，跨平台删键且不动入参', () {
      final src = <String, dynamic>{
        'download_dir': r'C:\x',
        'locale_code': 'zh-CN',
      };
      expect(
        filterSettingsForPlatform(
          src,
          sourcePlatform: 'windows',
          targetPlatform: 'windows',
        ),
        same(src),
      );
      final out = filterSettingsForPlatform(
        src,
        sourcePlatform: 'windows',
        targetPlatform: 'android',
      );
      expect(out.containsKey('download_dir'), isFalse);
      expect(out['locale_code'], 'zh-CN');
      expect(src.containsKey('download_dir'), isTrue, reason: '不得改动入参');
    });
  });
}
