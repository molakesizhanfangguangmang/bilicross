import 'dart:convert';
import 'dart:typed_data';

import 'package:bilicross/src/core/backup/backup_codec.dart';
import 'package:bilicross/src/core/backup/backup_format.dart';
import 'package:bilicross/src/core/backup/backup_key_ring.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定测试向量：下面这份 `.bcbak` 字节是用**另一套独立实现**（Node 的
/// `crypto.createCipheriv('aes-256-gcm', …)`）按 backup_format.dart 的布局算出来的，
/// 再拿 Dart 实现去比对。两边一致 = 格式契约可被第三方照文档复现，
/// 将来的独立解密工具只要拿到同样的 32 字节密钥就能解开正式备份。
///
/// 向量参数（全部为非敏感测试数据）：
/// - key：32 字节 `0x00..0x1F`（见 [kBackupTestKeyBase64]，公开测试密钥）
/// - nonce：12 字节 `0x00..0x0B`
/// - created_at：2026-09-19T00:00:00Z
/// - appVersion `1.0.6`、platform `windows`、payloadType `full`、keyId `v1`
/// - 载荷：`{"cookie":"SESSDATA=test-sess-vector; …","schema":1}`（假值）
const String _vectorHex = ''
    '424342414b424b3100010102'
    '7631'
    '000001a0b6f674'
    '000005312e302e36'
    '0777696e646f7773'
    '0466756c6c'
    '000102030405060708090a0b'
    '00000061'
    '3c20b574aa8eab7eaf7bb5d8f4ba2b29c282c609841e2c08151480f66e4476d7'
    '6264c18e94e170f118cd2087ebf3154c8b2a14a030b5d7f749f2496d7791cece'
    'b459a21f86a243135510975fdfbf3ed808baf953544f711b9e95fba119d283bcb6'
    'f6ccbbda3e87e2295ef565a2ef0d3fb7';

const String _vectorPayloadJson =
    '{"cookie":"SESSDATA=test-sess-vector; bili_jct=test-jct-vector; DedeUserID=100000001","schema":1}';

/// 测试用的假凭据，内容全部是中性值，不得替换成真实账号数据。
Map<String, dynamic> _testPayload() => <String, dynamic>{
      'cookie': 'SESSDATA=test-sess-vector; bili_jct=test-jct-vector; DedeUserID=100000001',
      'schema': 1,
    };

Uint8List _bytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fixedNonce() => Uint8List.fromList(List<int>.generate(12, (i) => i));

void main() {
  final codec = BackupCodec(keyRing: BackupKeyRing.testOnly());

  group('固定测试向量（跨实现一致）', () {
    test('用测试密钥 + 固定 nonce 编出来的字节与独立实现完全一致', () async {
      final bytes = await codec.encode(
        payload: _testPayload(),
        appVersion: '1.0.6',
        platform: 'windows',
        createdAt: DateTime.utc(2026, 9, 19),
        nonce: _fixedNonce(),
      );
      expect(_hex(bytes), _vectorHex);
    });

    test('能解开独立实现产出的那份备份', () async {
      final payload = await codec.decode(_bytes(_vectorHex));
      expect(payload.data['cookie'], contains('SESSDATA=test-sess-vector'));
      expect(payload.data['schema'], kBackupPayloadSchema);
      expect(jsonEncode(payload.data), _vectorPayloadJson);
    });

    test('头部元数据可读，且不依赖解密', () {
      final header = codec.readHeader(_bytes(_vectorHex));
      expect(header.formatVersion, kBackupFormatVersion);
      expect(header.algorithm, kBackupAlgorithmAes256Gcm);
      expect(header.keyId, kBackupCurrentKeyId);
      expect(header.appVersion, '1.0.6');
      expect(header.platform, 'windows');
      expect(header.payloadType, kBackupPayloadTypeFull);
      expect(header.createdAt.toUtc(), DateTime.utc(2026, 9, 19));
      expect(header.nonce.length, kBackupNonceLength);
      expect(header.cipherLength, utf8.encode(_vectorPayloadJson).length);
    });
  });

  group('往返', () {
    test('编码后解码拿回同一份载荷', () async {
      final payload = <String, dynamic>{
        'schema': kBackupPayloadSchema,
        'cookie': 'SESSDATA=test-sess; bili_jct=test-jct; DedeUserID=100000001',
        'token': <String, dynamic>{'access_token': 'test-token', 'expires_in': 3600},
        'settings': <String, dynamic>{'locale_code': 'zh-CN'},
        'tasks': <dynamic>[],
      };
      final bytes = await codec.encode(
        payload: payload,
        appVersion: '1.0.6',
        platform: 'android',
      );
      final decoded = await codec.decode(bytes);
      expect(jsonEncode(decoded.data), jsonEncode(payload));
      expect(decoded.header.platform, 'android');
    });

    test('每次编码的 nonce 都不同（同输入产生不同密文）', () async {
      final a = await codec.encode(
        payload: _testPayload(),
        appVersion: '1.0.6',
        platform: 'windows',
      );
      final b = await codec.encode(
        payload: _testPayload(),
        appVersion: '1.0.6',
        platform: 'windows',
      );
      expect(_hex(a), isNot(_hex(b)));
      expect(codec.readHeader(a).nonce, isNot(codec.readHeader(b).nonce));
    });
  });

  group('完整性、篡改与版本兼容', () {
    test('密文被改一位 → 认证失败', () async {
      final bytes = _bytes(_vectorHex);
      bytes[bytes.length - kBackupTagLength - 1] ^= 0x01;
      expect(
        () => codec.decode(bytes),
        throwsA(isA<BackupAuthenticationException>()),
      );
    });

    test('认证标签被改一位 → 认证失败', () async {
      final bytes = _bytes(_vectorHex);
      bytes[bytes.length - 1] ^= 0x01;
      expect(
        () => codec.decode(bytes),
        throwsA(isA<BackupAuthenticationException>()),
      );
    });

    test('头部被改（改创建时间）→ 认证失败（头部在 AAD 里）', () async {
      final bytes = _bytes(_vectorHex);
      bytes[20] ^= 0x01; // created_at 的最后一字节
      expect(
        () => codec.decode(bytes),
        throwsA(isA<BackupAuthenticationException>()),
      );
    });

    test('换一把密钥 → 认证失败，且错误信息不含凭据', () async {
      final otherKey = BackupKeyRing(<String, Uint8List>{
        kBackupCurrentKeyId: Uint8List.fromList(List<int>.generate(32, (i) => 255 - i)),
      });
      final other = BackupCodec(keyRing: otherKey);
      try {
        await other.decode(_bytes(_vectorHex));
        fail('应当认证失败');
      } on BackupAuthenticationException catch (error) {
        expect('$error'.contains('test-sess'), isFalse);
      }
    });

    test('不是备份文件 → 明确报格式错误', () {
      expect(
        () => codec.readHeader(_bytes('0011223344556677')),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('格式版本过新 → 明确报不支持', () {
      final bytes = _bytes(_vectorHex);
      bytes[9] = 9; // format_version 高位
      try {
        codec.readHeader(bytes);
        fail('应当报版本不支持');
      } on BackupFormatException catch (error) {
        expect('$error'.contains('格式版本不支持'), isTrue);
      }
    });

    test('未知 key_id → 明确报密钥版本不支持', () async {
      final bytes = _bytes(_vectorHex);
      final withOtherKeyId = Uint8List.fromList(bytes);
      // key_id 长度在偏移 11，内容在 12..13；把 'v1' 换成 'v9'
      withOtherKeyId[13] = 0x39;
      expect(
        () => codec.decode(withOtherKeyId),
        throwsA(isA<BackupKeyException>()),
      );
    });

    test('文件被截断 → 明确报不完整', () {
      final bytes = _bytes(_vectorHex);
      expect(
        () => codec.readHeader(Uint8List.sublistView(bytes, 0, bytes.length - 4)),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('不泄露明文', () {
    test('文件里看不到凭据原文，也没有 base64 形态的载荷', () async {
      final payload = <String, dynamic>{
        'schema': kBackupPayloadSchema,
        'cookie': 'SESSDATA=plaintext-probe-value; bili_jct=plaintext-probe-jct; '
            'DedeUserID=100000001',
      };
      final bytes = await codec.encode(
        payload: payload,
        appVersion: '1.0.6',
        platform: 'windows',
      );
      final asLatin = String.fromCharCodes(bytes);
      expect(asLatin.contains('plaintext-probe-value'), isFalse);
      expect(asLatin.contains('SESSDATA='), isFalse);
      expect(asLatin.contains('cookie'), isFalse);
      expect(asLatin.contains(base64Encode(utf8.encode(jsonEncode(payload)))), isFalse);
      expect(asLatin.contains(jsonEncode(payload)), isFalse);
    });
  });

  group('密钥环', () {
    test('没有注入正式密钥时判定为未配置，且编码给出明确错误', () async {
      final ring = BackupKeyRing(const <String, Uint8List>{});
      expect(ring.isConfigured, isFalse);
      final codecWithoutKey = BackupCodec(keyRing: ring);
      expect(
        () => codecWithoutKey.encode(
          payload: _testPayload(),
          appVersion: '1.0.6',
          platform: 'windows',
        ),
        throwsA(isA<BackupKeyException>()),
      );
    });

    test('测试密钥与正式密钥的读取入口分开', () {
      final testRing = BackupKeyRing.testOnly();
      expect(testRing.isConfigured, isTrue);
      expect(testRing.keyFor(kBackupCurrentKeyId)!.length, kBackupKeyLength);
      expect(testRing.keyFor('v2'), isNull);
    });

    test('测试密钥长度不对时报错，且信息里不含密钥内容', () {
      try {
        BackupKeyRing.testOnly('AAECAwQF');
        fail('应当报错');
      } on BackupKeyException catch (error) {
        expect('$error'.contains('AAECAwQF'), isFalse);
        expect('$error'.contains('32 字节'), isTrue);
      }
    });
  });
}
