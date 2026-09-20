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
const String _vectorHex =
    ''
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

/// 测试口令。长度必须 ≥ kBackupMinPassphraseLength。
const String _kPass = 'test-passphrase-1234';

/// v2 头部里各 KDF 字段的偏移。
///
/// ⚠️ 测试要篡改某个字段时**必须按布局算**，不能用 `indexOf` 猜 ——
/// 值等于某个数的字节到处都是（salt、时间戳里都有）。
({
  int kdfAlgorithm,
  int kdfMemory,
  int kdfIterations,
  int kdfParallelism,
  int kdfSalt,
})
_v2Offsets(Uint8List b) {
  var o = kBackupMagic.length + 2 + 1; // magic + format_version + algorithm
  o += 1 + b[o]; // key_id（uint8 长度 + 内容）
  o += 8; // created_at_ms
  o += 2 + ((b[o] << 8) | b[o + 1]); // app_version（uint16 大端）
  o += 1 + b[o]; // platform
  o += 1 + b[o]; // payload_type
  final kdf = o;
  return (
    kdfAlgorithm: kdf,
    kdfMemory: kdf + 1,
    kdfIterations: kdf + 5,
    kdfParallelism: kdf + 9,
    kdfSalt: kdf + 10,
  );
}

/// 按大端写入 uint32。
void _putUint32(Uint8List b, int offset, int value) {
  b[offset] = (value >> 24) & 0xff;
  b[offset + 1] = (value >> 16) & 0xff;
  b[offset + 2] = (value >> 8) & 0xff;
  b[offset + 3] = value & 0xff;
}

/// v2 跨实现固定测试向量的口令（公开，仅用于测试）。
const String _kV2VectorPassphrase = 'bilicross-test-vector-passphrase';

/// v2 跨实现固定测试向量。
///
/// **由独立的 Python 实现生成**（argon2-cffi 的 `hash_secret_raw` +
/// `cryptography` 的 AESGCM，按 backup_format.dart 的布局手工拼容器），
/// 不经过任何 Dart 代码 —— 所以它能验证 Dart 侧的字节布局与加密参数
/// 是否与文档一致，而不是自证。
///
/// 固定值：salt = 00..0f，nonce = 00..0b，memory 64 MiB / 迭代 3 / 并行 1，
/// app_version 2.0.2，platform android，时间戳固定。
/// 载荷是**虚假凭据**，不含任何真实数据。
const String _v2VectorHex =
    '424342414b424b310002010276310000019962b430000005322e302e3207616e64726f69640466756c6c01000100000000000301000102030405060708090a0b0c0d0e0f000102030405060708090a0b000000bfea1926208b4821d1f296bde42ad5c476954e14f518674e16e612e63473565f943e2945e836fc70abd1541a7b021fae56ffd8f2aacbcea1fce270bd07364613bd8b3b169ed52f87526cc9a7383127f4b0dc14ce6d12d850fb41c4a09fdac9962acfa6a6b09154cb948556396b120c0a03493b12791301a320b6efd42b457d800621a09ddeff2b226a7577692bd6b31299a5079a7e1575ef08b543d1fab7ec31c95bd0abbe9055264410a422bfa8532d8645f0a46a9a5663fa344098a67763a28559e89635efb80b1ceccbcd0b0737db';

const String _v2VectorPayloadJson =
    '{"schema":1,"cookie":"SESSDATA=vector-sess; bili_jct=vector-jct; DedeUserID=100000001","token":{"access_token":"vector-token","expires_in":3600},"settings":{"locale_code":"zh-CN"},"tasks":[]}';

void main() {
  final codec = BackupCodec(keyRing: BackupKeyRing.testOnly());

  group('固定测试向量（跨实现一致）', () {
    test('用测试密钥 + 固定 nonce 编出来的字节与独立实现完全一致', () async {
      // ⚠️ 固定向量是 **v1 格式**（构建期密钥、无口令），所以这里必须走
      // encodeLegacyWithInjectedKey —— 正式导出的 encode 现在一律是 v2 口令格式。
      final bytes = await codec.encodeLegacyWithInjectedKey(
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
      // 固定向量是 v1 格式 —— 这里断言的是**老格式常量**，不是当前常量。
      expect(header.formatVersion, kBackupFormatVersionLegacyNoPassword);
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
        'token': <String, dynamic>{
          'access_token': 'test-token',
          'expires_in': 3600,
        },
        'settings': <String, dynamic>{'locale_code': 'zh-CN'},
        'tasks': <dynamic>[],
      };
      final bytes = await codec.encode(
        payload: payload,
        passphrase: _kPass,
        appVersion: '1.0.6',
        platform: 'android',
      );
      final decoded = await codec.decode(bytes, passphrase: _kPass);
      expect(jsonEncode(decoded.data), jsonEncode(payload));
      expect(decoded.header.platform, 'android');
    });

    test('每次编码的 nonce 都不同（同输入产生不同密文）', () async {
      final a = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
        appVersion: '1.0.6',
        platform: 'windows',
      );
      final b = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
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
        kBackupCurrentKeyId: Uint8List.fromList(
          List<int>.generate(32, (i) => 255 - i),
        ),
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
        () =>
            codec.readHeader(Uint8List.sublistView(bytes, 0, bytes.length - 4)),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('口令（v2 格式）', () {
    test('口令备份往返一致，头部标记为口令保护', () async {
      final payload = _testPayload();
      final bytes = await codec.encode(
        payload: payload,
        passphrase: _kPass,
        appVersion: '2.0.2',
        platform: 'android',
      );
      final header = codec.readHeader(bytes);
      expect(header.formatVersion, kBackupFormatVersion);
      expect(header.usesPassphrase, isTrue);
      expect(header.kdfAlgorithm, kBackupKdfArgon2id);
      expect(header.kdfSalt.length, kBackupSaltLength);

      final decoded = await codec.decode(bytes, passphrase: _kPass);
      expect(jsonEncode(decoded.data), jsonEncode(payload));
    });

    test('口令错 → 明确报口令不对，且信息里不含凭据', () async {
      final bytes = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
        appVersion: '2.0.2',
        platform: 'android',
      );
      try {
        await codec.decode(bytes, passphrase: 'wrong-passphrase-9999');
        fail('应当认证失败');
      } on BackupPassphraseException catch (error) {
        expect('$error'.contains('test-sess'), isFalse);
      }
    });

    test('不给口令就解口令备份 → 明确要求输入口令', () async {
      final bytes = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
        appVersion: '2.0.2',
        platform: 'android',
      );
      expect(
        () => codec.decode(bytes),
        throwsA(isA<BackupPassphraseException>()),
      );
    });

    test('口令太短 → 拒绝导出（弱口令等于没加密）', () async {
      expect(
        () => codec.encode(
          payload: _testPayload(),
          passphrase: 'short',
          appVersion: '2.0.2',
          platform: 'android',
        ),
        throwsA(isA<BackupPassphraseException>()),
      );
    });

    test('同一个口令 + 不同 salt → 密文不同（salt 起作用）', () async {
      final a = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
        appVersion: '2.0.2',
        platform: 'android',
      );
      final b = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
        appVersion: '2.0.2',
        platform: 'android',
      );
      expect(
        _hex(codec.readHeader(a).kdfSalt),
        isNot(_hex(codec.readHeader(b).kdfSalt)),
      );
      expect(_hex(a), isNot(_hex(b)));
    });

    test('v2 写了未知 KDF 编号 → 只能是 BackupFormatException（不得当成 v1）', () async {
      final bytes = await codec.encode(
        payload: _testPayload(),
        passphrase: _kPass,
        appVersion: '2.0.2',
        platform: 'android',
      );
      // ⚠️ 不能用 indexOf 找 —— 值等于 1 的字节到处都是（salt、时间戳里都有）。
      // 按头部布局把 kdf_algorithm 的偏移算出来。
      var o = kBackupMagic.length + 2 + 1; // magic + format_version + algorithm
      o += 1 + bytes[o]; // key_id（uint8 长度 + 内容）
      o += 8; // created_at_ms
      o += 2 + ((bytes[o] << 8) | bytes[o + 1]); // app_version（uint16 大端）
      o += 1 + bytes[o]; // platform
      o += 1 + bytes[o]; // payload_type
      expect(bytes[o], kBackupKdfArgon2id, reason: '这个偏移应该正好是 kdf_algorithm');
      bytes[o] = 0x7f; // 未知 KDF 编号
      // ⚠️ 这里**只能**是 BackupFormatException。
      // 以前 `usesPassphrase` 为 false 会被当成 v1 走固定密钥分支，
      // 结果抛认证异常 —— 那是把「格式不认识」静默降级成「老格式」。
      // 现在按 format_version 分支，v2 就必须走口令派生，KDF 不认识就明确报错。
      await expectLater(
        () => codec.decode(bytes, passphrase: _kPass),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('老格式（v1）仍然能解 —— 新版不能把旧备份判死', () async {
      final payload = _testPayload();
      final legacy = await codec.encodeLegacyWithInjectedKey(
        payload: payload,
        appVersion: '1.0.6',
        platform: 'windows',
      );
      expect(codec.readHeader(legacy).usesPassphrase, isFalse);
      // 传了口令也不该影响：v1 走注入密钥那条路。
      final decoded = await codec.decode(legacy, passphrase: _kPass);
      expect(jsonEncode(decoded.data), jsonEncode(payload));
    });
  });

  group('v2 头部是不可信输入：KDF 参数必须在使用前校验', () {
    Future<Uint8List> validV2() => codec.encode(
      payload: _testPayload(),
      passphrase: _kPass,
      appVersion: '2.0.2',
      platform: 'android',
    );

    test('内存参数为 0 或超过上限 → 进 Argon2id 之前就被拒', () async {
      for (final bad in <int>[0, kBackupArgon2MemoryMaxKib + 1]) {
        final bytes = await validV2();
        _putUint32(bytes, _v2Offsets(bytes).kdfMemory, bad);
        await expectLater(
          () => codec.decode(bytes, passphrase: _kPass),
          throwsA(isA<BackupFormatException>()),
          reason: '内存参数 $bad 应当被拒',
        );
      }
    });

    test('迭代次数为 0 或超过上限 → 被拒', () async {
      for (final bad in <int>[0, kBackupArgon2IterationsMax + 1]) {
        final bytes = await validV2();
        _putUint32(bytes, _v2Offsets(bytes).kdfIterations, bad);
        await expectLater(
          () => codec.decode(bytes, passphrase: _kPass),
          throwsA(isA<BackupFormatException>()),
          reason: '迭代次数 $bad 应当被拒',
        );
      }
    });

    test('并行度为 0 或超过上限 → 被拒', () async {
      for (final bad in <int>[0, kBackupArgon2ParallelismMax + 1]) {
        final bytes = await validV2();
        bytes[_v2Offsets(bytes).kdfParallelism] = bad;
        await expectLater(
          () => codec.decode(bytes, passphrase: _kPass),
          throwsA(isA<BackupFormatException>()),
          reason: '并行度 $bad 应当被拒',
        );
      }
    });

    test('合法范围边界值仍然放行（校验不是一刀切）', () async {
      // 边界内的参数不该校验失败 —— 只是改了 KDF 段会让 AAD 对不上，
      // 所以这里断言的是「抛的不是 BackupFormatException」。
      final bytes = await validV2();
      _putUint32(bytes, _v2Offsets(bytes).kdfMemory, kBackupArgon2MemoryMinKib);
      await expectLater(
        () => codec.decode(bytes, passphrase: _kPass),
        throwsA(isNot(isA<BackupFormatException>())),
      );
    });

    test('报错信息里不含口令与载荷内容', () async {
      final bytes = await validV2();
      _putUint32(bytes, _v2Offsets(bytes).kdfMemory, 0);
      try {
        await codec.decode(bytes, passphrase: _kPass);
        fail('应当被拒');
      } on BackupFormatException catch (error) {
        expect('$error'.contains(_kPass), isFalse);
        expect('$error'.contains('test-sess'), isFalse);
      }
    });
  });

  group('v2 跨实现固定测试向量', () {
    test('能解开独立实现（Python + argon2-cffi + AESGCM）产出的备份', () async {
      final header = codec.readHeader(_bytes(_v2VectorHex));
      expect(header.formatVersion, kBackupFormatVersion);
      expect(header.algorithm, kBackupAlgorithmAes256Gcm);
      expect(header.usesPassphrase, isTrue);
      expect(header.kdfAlgorithm, kBackupKdfArgon2id);
      expect(header.platform, 'android');
      expect(header.appVersion, '2.0.2');

      final payload = await codec.decode(
        _bytes(_v2VectorHex),
        passphrase: _kV2VectorPassphrase,
      );
      expect(jsonEncode(payload.data), _v2VectorPayloadJson);
    });

    test('用错口令解这份向量 → 明确报口令不对', () async {
      await expectLater(
        () => codec.decode(
          _bytes(_v2VectorHex),
          passphrase: 'wrong-passphrase-9999',
        ),
        throwsA(isA<BackupPassphraseException>()),
      );
    });
  });

  group('不泄露明文', () {
    test('文件里看不到凭据原文，也没有 base64 形态的载荷', () async {
      final payload = <String, dynamic>{
        'schema': kBackupPayloadSchema,
        'cookie':
            'SESSDATA=plaintext-probe-value; bili_jct=plaintext-probe-jct; '
            'DedeUserID=100000001',
      };
      final bytes = await codec.encode(
        payload: payload,
        passphrase: _kPass,
        appVersion: '1.0.6',
        platform: 'windows',
      );
      final asLatin = String.fromCharCodes(bytes);
      expect(asLatin.contains('plaintext-probe-value'), isFalse);
      expect(asLatin.contains('SESSDATA='), isFalse);
      expect(asLatin.contains('cookie'), isFalse);
      expect(
        asLatin.contains(base64Encode(utf8.encode(jsonEncode(payload)))),
        isFalse,
      );
      expect(asLatin.contains(jsonEncode(payload)), isFalse);
    });
  });

  group('密钥环', () {
    test('没有注入正式密钥时判定为未配置，且编码给出明确错误', () async {
      final ring = BackupKeyRing(const <String, Uint8List>{});
      expect(ring.isConfigured, isFalse);
      final codecWithoutKey = BackupCodec(keyRing: ring);
      expect(
        () => codecWithoutKey.encodeLegacyWithInjectedKey(
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
