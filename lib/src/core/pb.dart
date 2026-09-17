import 'dart:convert';
import 'dart:typed_data';

/// 极简 protobuf 编解码：只覆盖用到的三种 wire type（varint、长度前缀、跳过）。
///
/// 只为 APP 端 PlayView 的请求与响应服务，字段数固定且少，手写比引入
/// protobuf 生成代码更轻；.proto 里的字段号见
/// `build/BBDownNext-source/BBDown.Core/APP/{Payload,Response}/*.proto`。
class PbWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void _varint(int value) {
    var rest = value;
    while (true) {
      final byte = rest & 0x7f;
      rest >>= 7;
      _out.addByte(rest == 0 ? byte : byte | 0x80);
      if (rest == 0) break;
    }
  }

  void varint(int field, int value) {
    _varint(field << 3);
    _varint(value);
  }

  void bytes(int field, List<int> value) {
    _varint(field << 3 | 2);
    _varint(value.length);
    _out.add(value);
  }

  void str(int field, String value) => bytes(field, utf8.encode(value));

  Uint8List toBytes() => _out.toBytes();
}

/// 一个已解出的字段：varint 走 [value]，长度前缀走 [bytes]。
class PbField {
  const PbField.number(this.number, this.value) : bytes = null;
  const PbField.bytes(this.number, this.bytes) : value = null;

  final int number;
  final int? value;
  final Uint8List? bytes;
}

/// 解一层字段；子消息交给调用方再递归一次。
List<PbField> pbFields(List<int> buffer) {
  final fields = <PbField>[];
  var index = 0;
  while (index < buffer.length) {
    var key = 0;
    var shift = 0;
    while (true) {
      final byte = buffer[index++];
      key |= (byte & 0x7f) << shift;
      shift += 7;
      if (byte & 0x80 == 0) break;
      if (index >= buffer.length || shift > 63) {
        throw const FormatException('protobuf 键读越界');
      }
    }
    final field = key >> 3;
    final wire = key & 7;
    switch (wire) {
      case 0:
        var value = 0;
        shift = 0;
        while (true) {
          final byte = buffer[index++];
          value |= (byte & 0x7f) << shift;
          shift += 7;
          if (byte & 0x80 == 0) break;
          if (index >= buffer.length || shift > 63) {
            throw const FormatException('protobuf varint 读越界');
          }
        }
        fields.add(PbField.number(field, value));
      case 2:
        var length = 0;
        shift = 0;
        while (true) {
          final byte = buffer[index++];
          length |= (byte & 0x7f) << shift;
          shift += 7;
          if (byte & 0x80 == 0) break;
          if (index >= buffer.length || shift > 63) {
            throw const FormatException('protobuf 长度读越界');
          }
        }
        if (index + length > buffer.length) {
          throw const FormatException('protobuf 长度超出缓冲');
        }
        fields.add(PbField.bytes(field, Uint8List.fromList(
          buffer.sublist(index, index + length),
        )));
        index += length;
      case 1:
        if (index + 8 > buffer.length) {
          throw const FormatException('protobuf 定长 64 位读越界');
        }
        fields.add(PbField.bytes(field, Uint8List.fromList(
          buffer.sublist(index, index + 8),
        )));
        index += 8;
      case 5:
        if (index + 4 > buffer.length) {
          throw const FormatException('protobuf 定长 32 位读越界');
        }
        fields.add(PbField.bytes(field, Uint8List.fromList(
          buffer.sublist(index, index + 4),
        )));
        index += 4;
      default:
        throw FormatException('未知 protobuf wire type $wire');
    }
  }
  return fields;
}

int? pbInt(List<PbField> fields, int number) {
  for (final field in fields) {
    if (field.number == number && field.value != null) return field.value;
  }
  return null;
}

Uint8List? pbChunk(List<PbField> fields, int number) {
  for (final field in fields) {
    if (field.number == number && field.bytes != null) return field.bytes;
  }
  return null;
}

List<Uint8List> pbChunks(List<PbField> fields, int number) => [
      for (final field in fields)
        if (field.number == number && field.bytes != null) field.bytes!,
    ];

/// 概率极低的非 UTF-8 也当空串处理，不让一个字段毁掉整份响应。
String pbText(List<PbField> fields, int number) {
  final raw = pbChunk(fields, number);
  if (raw == null) return '';
  try {
    return utf8.decode(raw);
  } on FormatException {
    return '';
  }
}
