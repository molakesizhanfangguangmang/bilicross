import 'dart:convert';
import 'dart:typed_data';

/// `.bcbak` 备份容器的格式定义。
///
/// 这个文件是**格式契约**：内容都是公开常量与纯函数，不涉及密钥，也不依赖 Flutter。
/// 将来任何独立实现（别的语言、别的工具）按这里的字节布局写就能解开正式备份 ——
/// 因此所有长度、端序、编码都写死在下面，不要在别处再定义一套。
///
/// ## 容器布局（`format_version = 1`）
///
/// | 偏移 | 长度 | 字段 | 说明 |
/// |---|---|---|---|
/// | 0 | 8 | `magic` | ASCII `BCBAKBK1`，固定标识 + 容器版本 |
/// | 8 | 2 | `format_version` | uint16，**大端**，当前 `1` |
/// | 10 | 1 | `algorithm` | uint8，`1` = AES-256-GCM |
/// | 11 | 1+N | `key_id` | uint8 长度 + UTF-8 字节，如 `v1` |
/// | … | 8 | `created_at_ms` | uint64，**大端**，UTC 毫秒 |
/// | … | 2+N | `app_version` | uint16 长度（大端）+ UTF-8，如 `1.0.6` |
/// | … | 1+N | `platform` | uint8 长度 + UTF-8，`android` / `windows` / … |
/// | … | 1+N | `payload_type` | uint8 长度 + UTF-8，当前只有 `full` |
/// | … | 12 | `nonce` | 随机字节，AES-GCM 固定 12 字节 |
/// | … | 4 | `cipher_length` | uint32，**大端**，密文字节数 |
/// | … | C | `ciphertext` | AES-256-GCM 密文（长度 = `cipher_length`）|
/// | … | 16 | `authentication_tag` | AES-GCM 认证标签，16 字节 |
///
/// **附加认证数据（AAD）= 从 `magic` 起、到 `cipher_length` 结束（含）的全部字节**，
/// 也就是密文之前的整个头部。这样改头部任何一位（包括改创建时间）都会认证失败。
///
/// ## 约定
///
/// - 所有多字节整数一律**大端**（网络字节序）。
/// - 所有字符串一律 **UTF-8**，长度字段按**字节数**计，不是字符数。
/// - 明文载荷是 UTF-8 编码的 JSON（`payload_schema` 见 [kBackupPayloadSchema]），
///   它整体位于 `ciphertext` 之内，文件里看不到明文。
/// - 密钥 32 字节（AES-256），nonce 12 字节，tag 16 字节；
///   密钥用 base64 文本在构建期注入，见 `backup_key_ring.dart`。
/// - 未知的 `format_version` / `algorithm` / `key_id` 一律明确报错，不做猜测。
const List<int> kBackupMagic = <int>[0x42, 0x43, 0x42, 0x41, 0x4B, 0x42, 0x4B, 0x31];

/// magic 的 ASCII 形式，报错信息与测试里用。
const String kBackupMagicText = 'BCBAKBK1';

/// 当前备份格式版本。格式变化时递增，并按 [kBackupMagic] 一并演进。
const int kBackupFormatVersion = 1;

/// 加密算法编号。
const int kBackupAlgorithmAes256Gcm = 1;

/// 当前使用的算法编号。
const int kBackupAlgorithm = kBackupAlgorithmAes256Gcm;

/// AES-256-GCM 参数（写死，避免实现之间产生偏差）。
const int kBackupKeyLength = 32;
const int kBackupNonceLength = 12;
const int kBackupTagLength = 16;

/// 明文载荷的 schema 版本（载荷是 JSON，这个是 JSON 里的 `schema` 字段）。
const int kBackupPayloadSchema = 1;

/// 载荷类型：目前只有整包覆盖式备份。
const String kBackupPayloadTypeFull = 'full';

/// 备份文件扩展名（含点）。
const String kBackupExtension = '.bcbak';

/// 文件大小上限：防止把超大文件当备份读进来。整包 JSON 不该超过 64 MiB。
const int kBackupMaxBytes = 64 * 1024 * 1024;

/// 头部里除密文与 tag 之外的部分，供 AAD 使用。
class BackupHeader {
  const BackupHeader({
    required this.formatVersion,
    required this.algorithm,
    required this.keyId,
    required this.createdAt,
    required this.appVersion,
    required this.platform,
    required this.payloadType,
    required this.nonce,
    required this.cipherLength,
  });

  final int formatVersion;
  final int algorithm;
  final String keyId;
  final DateTime createdAt;
  final String appVersion;
  final String platform;
  final String payloadType;
  final Uint8List nonce;
  final int cipherLength;

  /// AAD：头部序列化后的字节（密文之前的所有内容）。
  Uint8List toAadBytes() => _writeHeader(this);
}

/// 头部字段长度上限，防止畸形文件把内存吃满。
const int _kKeyIdMax = 64;
const int _kStringMax = 256;

/// 把头部序列化成字节。顺序即上面的表格，改动等于改格式。
Uint8List _writeHeader(BackupHeader header) {
  final builder = BytesBuilder(copy: false);
  builder.add(kBackupMagic);
  builder.add(_uint16(header.formatVersion));
  builder.add(<int>[header.algorithm]);
  builder.add(_string8(header.keyId));
  builder.add(_uint64(header.createdAt.toUtc().millisecondsSinceEpoch));
  builder.add(_string16(header.appVersion));
  builder.add(_string8(header.platform));
  builder.add(_string8(header.payloadType));
  builder.add(header.nonce);
  builder.add(_uint32(header.cipherLength));
  return builder.toBytes();
}

/// 序列化完整容器。
Uint8List serializeBackup({
  required BackupHeader header,
  required Uint8List ciphertext,
  required Uint8List authenticationTag,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add(header.toAadBytes());
  builder.add(ciphertext);
  builder.add(authenticationTag);
  return builder.toBytes();
}

/// 头部 + 密文 + tag 的解析结果。
class ParsedBackup {
  const ParsedBackup({
    required this.header,
    required this.ciphertext,
    required this.authenticationTag,
  });

  final BackupHeader header;
  final Uint8List ciphertext;
  final Uint8List authenticationTag;
}

/// 只解析头部与分段，不做解密。界面在提示「是否覆盖」之前用它读创建时间/来源版本。
///
/// 结构不对就抛 [BackupFormatException]，错误信息里不含任何载荷内容。
ParsedBackup parseBackup(Uint8List bytes) {
  if (bytes.length > kBackupMaxBytes) {
    throw BackupFormatException('备份文件过大（${bytes.length} 字节），已超出上限');
  }
  final reader = _Reader(bytes);
  final magic = reader.take(kBackupMagic.length);
  if (!_sameBytes(magic, kBackupMagic)) {
    throw BackupFormatException('不是 $kBackupMagicText 备份文件，或文件已损坏');
  }
  final formatVersion = reader.uint16();
  if (formatVersion != kBackupFormatVersion) {
    throw BackupFormatException('备份格式版本不支持：$formatVersion（当前支持 $kBackupFormatVersion）');
  }
  final algorithm = reader.uint8();
  if (algorithm != kBackupAlgorithmAes256Gcm) {
    throw BackupFormatException('备份算法不支持：$algorithm（当前支持 AES-256-GCM=$kBackupAlgorithmAes256Gcm）');
  }
  final keyId = reader.string8(_kKeyIdMax);
  final createdAtMs = reader.uint64();
  final appVersion = reader.string16(_kStringMax);
  final platform = reader.string8(_kStringMax);
  final payloadType = reader.string8(_kStringMax);
  final nonce = reader.take(kBackupNonceLength);
  final cipherLength = reader.uint32();
  if (cipherLength > reader.remaining) {
    throw BackupFormatException('备份文件不完整：密文长度 $cipherLength 超出剩余字节');
  }
  final header = BackupHeader(
    formatVersion: formatVersion,
    algorithm: algorithm,
    keyId: keyId,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
    appVersion: appVersion,
    platform: platform,
    payloadType: payloadType,
    nonce: nonce,
    cipherLength: cipherLength,
  );
  final ciphertext = reader.take(cipherLength);
  final tag = reader.take(kBackupTagLength);
  if (reader.remaining != 0) {
    throw BackupFormatException('备份文件尾部有 ${reader.remaining} 个多余字节，可能被改过');
  }
  return ParsedBackup(
    header: header,
    ciphertext: ciphertext,
    authenticationTag: tag,
  );
}

/// 备份文件的结构或版本问题。**错误信息不得包含任何凭据内容。**
class BackupFormatException implements Exception {
  BackupFormatException(this.message);

  final String message;

  @override
  String toString() => '备份文件无法读取：$message';
}

Uint8List _uint16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

Uint8List _uint64(int value) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.big);

Uint8List _string8(String value) {
  final body = utf8.encode(value);
  return Uint8List.fromList(<int>[body.length, ...body]);
}

Uint8List _string16(String value) {
  final body = utf8.encode(value);
  final head = _uint16(body.length);
  return Uint8List.fromList(<int>[...head, ...body]);
}

bool _sameBytes(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int get remaining => _bytes.length - _offset;

  Uint8List take(int length) {
    if (length < 0 || remaining < length) {
      throw BackupFormatException('备份文件不完整：还差 ${length - remaining} 个字节');
    }
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(slice);
  }

  int uint8() => take(1)[0];

  int uint16() => ByteData.sublistView(take(2)).getUint16(0, Endian.big);

  int uint32() => ByteData.sublistView(take(4)).getUint32(0, Endian.big);

  int uint64() => ByteData.sublistView(take(8)).getUint64(0, Endian.big);

  String string8(int max) {
    final length = uint8();
    if (length > max) {
      throw BackupFormatException('备份文件字段长度异常：$length');
    }
    return utf8.decode(take(length), allowMalformed: false);
  }

  String string16(int max) {
    final length = uint16();
    if (length > max) {
      throw BackupFormatException('备份文件字段长度异常：$length');
    }
    return utf8.decode(take(length), allowMalformed: false);
  }
}
