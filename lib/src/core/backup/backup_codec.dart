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
/// 算法：AES-256-GCM（AEAD）。密钥 32 字节、nonce 12 字节、认证标签 16 字节；
/// GCM 是无填充流模式，**密文长度等于明文长度**，所以头部能在加密前写全，
/// AAD 取「密文之前的整个头部」。
class BackupCodec {
  BackupCodec({required this.keyRing, this.random});

  final BackupKeyRing keyRing;

  /// 测试可以注入固定随机源，正式运行用 [Random.secure]。
  final Random? random;

  static final AesGcm _algorithm = AesGcm.with256bits();

  /// 编码：把明文载荷（JSON）加密封装成 `.bcbak` 字节。
  ///
  /// [nonce] 只在测试里给（用来复现固定测试向量），正式调用不要传。
  Future<Uint8List> encode({
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
      throw BackupKeyException('本次构建没有注入备份密钥（$kBackupKeyDefine），无法创建备份');
    }
    final body = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final header = BackupHeader(
      formatVersion: kBackupFormatVersion,
      algorithm: kBackupAlgorithm,
      keyId: keyId,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
      appVersion: appVersion,
      platform: platform,
      payloadType: payloadType,
      nonce: nonce ?? _randomNonce(),
      cipherLength: body.length,
    );
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

  /// 解码：校验认证标签并解出明文载荷。任何格式、版本、密钥或篡改问题都抛明确异常。
  Future<BackupPayload> decode(Uint8List bytes) async {
    final parsed = parseBackup(bytes);
    final keyBytes = keyRing.keyFor(parsed.header.keyId);
    if (keyBytes == null) {
      throw BackupKeyException(
        '这份备份用的是 key_id=${parsed.header.keyId}，当前版本不支持该密钥版本',
      );
    }
    final box = SecretBox(
      parsed.ciphertext,
      nonce: parsed.header.nonce,
      mac: Mac(parsed.authenticationTag),
    );
    final List<int> clear;
    try {
      clear = await _algorithm.decrypt(
        box,
        secretKey: SecretKey(keyBytes),
        aad: parsed.header.toAadBytes(),
      );
    } on SecretBoxAuthenticationError {
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
    return BackupPayload(header: parsed.header, data: data);
  }

  /// 只读头部：界面在弹出「会覆盖当前数据」的确认框之前用它显示创建时间与来源版本。
  BackupHeader readHeader(Uint8List bytes) => parseBackup(bytes).header;

  Uint8List _randomNonce() {
    final source = random ?? Random.secure();
    final nonce = Uint8List(kBackupNonceLength);
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = source.nextInt(256);
    }
    return nonce;
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
