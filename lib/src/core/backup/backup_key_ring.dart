/// 备份密钥的注入与轮换。
///
/// **正式密钥不进仓库**：构建期通过
/// `--dart-define=BILICROSS_BACKUP_KEY_V1=<base64 的 32 字节>` 注入，
/// CI 从 GitHub Secret 取同名值。这里只出现名字，不打印、不落盘、不进日志。
/// 密钥由项目所有者生成与保管；代码只负责按 `key_id` 取用。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 正式密钥的构建期注入名。
const String kBackupKeyDefine = 'BILICROSS_BACKUP_KEY_V1';

/// 测试密钥的构建期注入名（与正式密钥完全分开，允许公开：它只用于单元测试）。
const String kBackupTestKeyDefine = 'BILICROSS_BACKUP_TEST_KEY_V1';

/// 固定的测试密钥：32 字节 0x00…0x1F 的 base64。
/// 它**只用于测试**，正式构建必须用 Secret 注入的真密钥；两者不得混用。
const String kBackupTestKeyBase64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

/// 当前用于**新建**备份的 key_id。轮换时新增 key_id 并把它设为默认，
/// 旧 key_id 继续保留只读解密能力。
const String kBackupCurrentKeyId = 'v1';

/// 构建期注入的正式密钥（base64 文本，空表示这次构建没有注入）。
const String kInjectedBackupKey = String.fromEnvironment(kBackupKeyDefine);

/// 构建期注入的测试密钥；未注入时回落到固定的公开测试密钥。
const String kInjectedTestKey = String.fromEnvironment(
  kBackupTestKeyDefine,
  defaultValue: kBackupTestKeyBase64,
);

/// 按 key_id 取密钥的集合。默认只认识 [kBackupCurrentKeyId]。
class BackupKeyRing {
  BackupKeyRing(Map<String, Uint8List> keys, {this.currentKeyId = kBackupCurrentKeyId})
      : _keys = Map<String, Uint8List>.unmodifiable(
          keys.map((k, v) => MapEntry(k, Uint8List.fromList(v))),
        );

  /// 从构建期注入的常量组装。没有注入正式密钥时 [isConfigured] 为 false。
  factory BackupKeyRing.fromEnvironment() {
    final raw = kInjectedBackupKey.trim();
    if (raw.isEmpty) return BackupKeyRing(const <String, Uint8List>{});
    return BackupKeyRing(<String, Uint8List>{
      kBackupCurrentKeyId: _decodeKey(raw, kBackupKeyDefine),
    });
  }

  /// 测试用：只用测试密钥组装的钥匙环。
  factory BackupKeyRing.testOnly([String base64Key = kInjectedTestKey]) =>
      BackupKeyRing(<String, Uint8List>{
        kBackupCurrentKeyId: _decodeKey(base64Key.trim(), kBackupTestKeyDefine),
      });

  final Map<String, Uint8List> _keys;
  final String currentKeyId;

  bool get isConfigured => _keys.containsKey(currentKeyId);

  Iterable<String> get keyIds => _keys.keys;

  /// 取密钥；不认识这个 key_id 时返回 null（调用方给出明确错误）。
  Uint8List? keyFor(String keyId) => _keys[keyId];

  static Uint8List _decodeKey(String base64Text, String defineName) {
    final List<int> bytes;
    try {
      bytes = base64Decode(base64Text);
    } on FormatException {
      throw BackupKeyException('$defineName 不是合法的 base64');
    }
    if (bytes.length != 32) {
      throw BackupKeyException('$defineName 解出来是 ${bytes.length} 字节，AES-256 需要 32 字节');
    }
    return Uint8List.fromList(bytes);
  }
}

/// 密钥缺失或格式不对。**错误信息里不得出现密钥内容。**
class BackupKeyException implements Exception {
  BackupKeyException(this.message);

  final String message;

  @override
  String toString() => '备份密钥不可用：$message';
}
