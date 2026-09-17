import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// WBI 签名与 APP 签名。两者都是 md5，但拼接方式不同，且 WBI 需要 mixin key。
///
/// mixin key 的取样表来自网页端实现，顺序固定；对同一组 img/sub key，
/// 结果可离线复核（例如 img=7cd084941338484aae1ad9425b84077c、
/// sub=4932caff0ff746eab6f01bf08b70ac45 时 mixin key 为
/// ea1db124af3c7062474693fa704f4ff8）。
const List<int> mixinKeyTable = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, //
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, //
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, //
  22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

String mixinKeyFrom(String imgKey, String subKey) {
  final joined = '$imgKey$subKey';
  final buffer = StringBuffer();
  for (final index in mixinKeyTable) {
    if (index < joined.length) {
      buffer.write(joined[index]);
    }
  }
  final filtered = buffer.toString().replaceAll(RegExp('[!\'()*]'), '');
  return filtered.length >= 32 ? filtered.substring(0, 32) : filtered;
}

/// 网页端的 encodeURIComponent 不编码 `!'()*`，Dart 的 encodeComponent 同样保留它们，
/// 这里再兜一层还原，避免两边实现差异改变签名。
String encodeComponent(String value) => Uri.encodeComponent(value)
    .replaceAll('%21', '!')
    .replaceAll('%27', '\'')
    .replaceAll('%28', '(')
    .replaceAll('%29', ')')
    .replaceAll('%2A', '*');

/// 参数按键名排序后用 `&` 连接，键与值都做网页同款编码。
String buildQuery(Map<String, String> params) {
  final keys = params.keys.toList()..sort();
  return keys.map((key) => '${encodeComponent(key)}=${encodeComponent(params[key]!)}').join('&');
}

String wbiSign({required Map<String, String> params, required String mixinKey}) {
  final query = buildQuery(params);
  return md5Hex('$query$mixinKey');
}

/// APP 签名：按构造顺序拼接的参数串 + appsec 取 md5。
String appSign({required String query, required String appSecret}) =>
    md5Hex('$query$appSecret');

/// 从 `https://i0.hdslb.com/bfs/wbi/xxxx.png` 这样的地址里取出 key 本身。
String wbiKeyFromUrl(String url) {
  final name = url.split('/').last;
  final dot = name.indexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

/// Cookie 解析：兼容 Netscape `cookie.txt` 与普通 Cookie 请求头。
class CookieParser {
  const CookieParser._();

  static const List<String> _sessDataNames = ['SESSDATA'];
  static const List<String> _csrfNames = ['bili_jct'];
  static const List<String> _uidNames = ['DedeUserID'];

  static WebCookie parse(String input) {
    var text = input.trim();
    if (text.toLowerCase().startsWith('cookie:')) {
      text = text.substring('cookie:'.length).trim();
    }
    final fields = <String, String>{};
    for (final rawLine in const LineSplitter().convert(text)) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (!line.startsWith('#HttpOnly_')) continue;
        line = line.substring('#HttpOnly_'.length);
      }
      if (line.contains('\t')) {
        final parts = line.split('\t');
        if (parts.length >= 7) {
          final name = parts[5].trim();
          final value = parts.sublist(6).join('\t').trim();
          if (name.isNotEmpty && value.isNotEmpty) {
            fields.putIfAbsent(name, () => value);
          }
        }
        continue;
      }
      for (final piece in line.split(';')) {
        final index = piece.indexOf('=');
        if (index <= 0) continue;
        final name = piece.substring(0, index).trim();
        final value = piece.substring(index + 1).trim();
        if (name.isNotEmpty && value.isNotEmpty) {
          fields.putIfAbsent(name, () => value);
        }
      }
    }

    final sessData = _pick(fields, _sessDataNames);
    final biliJct = _pick(fields, _csrfNames);
    final dedeUserId = _pick(fields, _uidNames);
    final raw = sessData.isEmpty
        ? ''
        : 'SESSDATA=$sessData; bili_jct=$biliJct; DedeUserID=$dedeUserId';
    return WebCookie(
      raw: raw,
      sessData: sessData,
      biliJct: biliJct,
      dedeUserId: dedeUserId,
    );
  }

  static String _pick(Map<String, String> fields, List<String> names) {
    for (final name in names) {
      final value = fields[name];
      if (value != null && value.isNotEmpty) return value;
    }
    // 字段名大小写不一致时再整体扫一遍
    for (final entry in fields.entries) {
      for (final name in names) {
        if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
      }
    }
    return '';
  }
}
