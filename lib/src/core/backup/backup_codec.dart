import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backup_format.dart';
import 'backup_key_ring.dart';

/// 备份的编码（加密）与解码（解密）入口。
///
/// 纯 Dart：不依赖 Flutter、窗口、WebView 或平台通道，可以在单元测试里直接跑，
/// 也可以被别的 Dart 程序引用。字节布局与参数全部写在 [backup_format.dart]，
/// 按那份文档用任何语言重写都能解开正式备份。
///
/// ## 两种密钥形态
///
/// | 形态 | 格式版本 | 密钥来源 | 用途 |
/// |---|---|---|---|
/// | **口令派生** | 2 | 用户输入的口令 + Argon2id | **新建备份（唯一入口）** |
/// | 构建期注入 | 1 | `--dart-define` 注入的固定密钥 | 只用来**读老备份** |
///
/// ⚠️ **新版必须能读 v1**：用户升级前导出的备份不能被判死。
/// 所以 [decode] 按头部里的 `format_version` 分支，两条路都走。
///
/// ## 加密参数
///
/// AES-256-GCM（AEAD）。密钥 32 字节、nonce 12 字节、认证标签 16 字节；
/// GCM 是无填充流模式，**密文长度等于明文长度**，所以头部能在加密前写全，
/// AAD 取「密文之前的整个头部」。
class BackupCodec {
  BackupCodec({required this.keyRing, this.random});

  final BackupKeyRing keyRing;

  /// 测试可以注入固定随机源，正式运行用 [Random.secure]。
  final Random? random;

  static final AesGcm _algorithm = AesGcm.with256bits();

  /// 新建备份：**必须给口令**，用 Argon2id 派生密钥后加密（v2 格式）。
  ///
  /// [salt] / [nonce] 只在测试里给（用来复现固定向量），正式调用不要传。
  Future<Uint8List> encode({
    required Map<String, dynamic> payload,
    required String passphrase,
    required String appVersion,
    required String platform,
    String payloadType = kBackupPayloadTypeFull,
    DateTime? createdAt,
    Uint8List? salt,
    Uint8List? nonce,
  }) async {
    final trimmed = passphrase.trim();
    if (trimmed.length < kBackupMinPassphraseLength) {
      throw BackupPassphraseException(
        '口令至少 $kBackupMinPassphraseLength 位（弱口令等于没加密）',
      );
    }
    final actualSalt = salt ?? _randomBytes(kBackupSaltLength);
    if (actualSalt.length != kBackupSaltLength) {
      throw BackupPassphraseException('salt 必须是 $kBackupSaltLength 字节');
    }
    final body = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final header = BackupHeader(
      formatVersion: kBackupFormatVersion,
      algorithm: kBackupAlgorithm,
      keyId: kBackupCurrentKeyId,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
      appVersion: appVersion,
      platform: platform,
      payloadType: payloadType,
      nonce: nonce ?? _randomBytes(kBackupNonceLength),
      cipherLength: body.length,
      kdfAlgorithm: kBackupKdfArgon2id,
      kdfMemoryKib: kBackupArgon2MemoryKib,
      kdfIterations: kBackupArgon2Iterations,
      kdfParallelism: kBackupArgon2Parallelism,
      kdfSalt: actualSalt,
    );
    final keyBytes = await _deriveFromPassphrase(
      passphrase: trimmed,
      salt: actualSalt,
      header: header,
    );
    return _seal(header: header, body: body, keyBytes: keyBytes);
  }

  /// **仅供测试与兼容验证**：用构建期注入的密钥写 v1 格式。
  ///
  /// 存在的意义只有一个 —— 造出一份老格式备份，验证「新版能读 v1」。
  /// 正式导出不走这里（导出必须带口令）。
  Future<Uint8List> encodeLegacyWithInjectedKey({
    required Map<String, dynamic> payload,
    required String appVersion,
    required String platform,
    String payloadType = kBackupPayloadTypeFull,
    DateTime? createdAt,
    Uint8List? nonce,
  }) async {
    final keyId = keyRing.currentKeyId;
    final keyBytes = keyRing.keyFor(keyId);
    if (keyBytes == null) {
      throw BackupKeyException(
        '本次构建没有注入备份密钥（$kBackupKeyDefine），无法创建老格式备份',
      );
    }
    final body = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final header = BackupHeader(
      formatVersion: kBackupFormatVersionLegacyNoPassword,
      algorithm: kBackupAlgorithm,
      keyId: keyId,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
      appVersion: appVersion,
      platform: platform,
      payloadType: payloadType,
      nonce: nonce ?? _randomBytes(kBackupNonceLength),
      cipherLength: body.length,
    );
    return _seal(header: header, body: body, keyBytes: keyBytes);
  }

  /// 解码：校验认证标签并解出明文载荷。
  ///
  /// - 口令备份（v2）→ 必须给 [passphrase]，缺了直接报错，不猜。
  /// - 老格式（v1）→ 用构建期注入的密钥，忽略 [passphrase]。
  Future<BackupPayload> decode(Uint8List bytes, {String? passphrase}) async {
    final parsed = parseBackup(bytes);
    final header = parsed.header;

    final Uint8List keyBytes;
    if (header.usesPassphrase) {
      final trimmed = (passphrase ?? '').trim();
      if (trimmed.isEmpty) {
        throw BackupPassphraseException('这份备份用口令保护，需要输入口令才能恢复');
      }
      keyBytes = await _deriveFromPassphrase(
        passphrase: trimmed,
        salt: header.kdfSalt,
        header: header,
      );
    } else {
      final injected = keyRing.keyFor(header.keyId);
      if (injected == null) {
        throw BackupKeyException(
          '这份备份用的是 key_id=${header.keyId}，当前版本不支持该密钥版本',
        );
      }
      keyBytes = injected;
    }

    final box = SecretBox(
      parsed.ciphertext,
      nonce: header.nonce,
      mac: Mac(parsed.authenticationTag),
    );
    final List<int> clear;
    try {
      clear = await _algorithm.decrypt(
        box,
        secretKey: SecretKey(keyBytes),
        aad: header.toAadBytes(),
      );
    } on SecretBoxAuthenticationError {
      // ⚠️ AEAD 分不清「口令错」和「文件被改」—— 两者都表现为认证失败。
      // 但按头部能判断是不是口令备份，据此给更贴切的提示。
      if (header.usesPassphrase) {
        throw BackupPassphraseException('口令不对，或备份文件已损坏 / 被修改');
      }
      throw BackupAuthenticationException();
    }
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic>) {
        throw BackupFormatException('载荷不是 JSON 对象');
      }
      data = decoded;
    } on FormatException {
      throw BackupFormatException('载荷不是合法的 UTF-8 JSON');
    }
    final schema = data['schema'];
    if (schema != kBackupPayloadSchema) {
      throw BackupFormatException('载荷 schema 不支持：$schema（当前支持 $kBackupPayloadSchema）');
    }
    return BackupPayload(header: header, data: data);
  }

  /// 只读头部：界面在弹出「会覆盖当前数据」的确认框之前用它显示创建时间与来源版本。
  ///
  /// 也用来判断「这份备份要不要先问口令」——见 [BackupHeader.usesPassphrase]。
  BackupHeader readHeader(Uint8List bytes) => parseBackup(bytes).header;

  /// 按头部里记的 KDF 参数派生密钥。
  ///
  /// ⚠️ 参数从**头部**读，不是从常量读 —— 以后调参（加大内存/迭代）时，
  /// 老备份照样能按它自己记的参数解出来。
  Future<Uint8List> _deriveFromPassphrase({
    required String passphrase,
    required List<int> salt,
    required BackupHeader header,
  }) async {
    if (header.kdfAlgorithm != kBackupKdfArgon2id) {
      throw BackupFormatException(
        '这份备份的密钥派生算法不支持：${header.kdfAlgorithm}（当前支持 $kBackupKdfArgon2id = Argon2id）',
      );
    }
    final kdf = Argon2id(
      parallelism: header.kdfParallelism,
      memory: header.kdfMemoryKib,
      iterations: header.kdfIterations,
      hashLength: kBackupKeyLength,
    );
    final derived = await kdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  Future<Uint8List> _seal({
    required BackupHeader header,
    required Uint8List body,
    required Uint8List keyBytes,
  }) async {
    final aad = header.toAadBytes();
    final box = await _algorithm.encrypt(
      body,
      secretKey: SecretKey(keyBytes),
      nonce: header.nonce,
      aad: aad,
    );
    return serializeBackup(
      header: header,
      ciphertext: Uint8List.fromList(box.cipherText),
      authenticationTag: Uint8List.fromList(box.mac.bytes),
    );
  }

  Uint8List _randomBytes(int length) {
    final source = random ?? Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = source.nextInt(256);
    }
    return bytes;
  }
}

/// 解码结果：头部元数据 + 明文载荷。
class BackupPayload {
  const BackupPayload({required this.header, required this.data});

  final BackupHeader header;
  final Map<String, dynamic> data;
}

/// 认证失败：文件损坏、被改过，或密钥不匹配。**信息里不含任何凭据内容。**
class BackupAuthenticationException implements Exception {
  @override
  String toString() => '备份校验失败：文件可能已损坏或被修改，或与当前版本不匹配';
}

/// 口令相关的问题：太短、缺失、或不对。**信息里不含任何凭据内容。**
class BackupPassphraseException implements Exception {
  BackupPassphraseException(this.message);

  final String message;

  @override
  String toString() => message;
}
