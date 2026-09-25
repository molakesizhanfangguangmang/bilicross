import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'announcement.dart';

/// 生成一个设备标识：16 字节随机数的十六进制。
///
/// ⚠️ 只用来给投票去重，**不含任何设备信息**（不读 ANDROID_ID、不读序列号），
/// 换设备或清数据就是一个新投手 —— 这是已知且可接受的强度。
String newDeviceId([Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 提交一票。网络异常、服务端拒绝都返回 false，不往外抛。
///
/// ⚠️ 单选**不给改票入口**：界面投完即固定，这里的 options 只会提交一次。
Future<bool> submitVote({
  required String pollId,
  required String deviceId,
  required List<String> options,
  http.Client? client,
  String baseUrl = kAnnouncementsBaseUrl,
  Duration timeout = kAnnouncementTimeout,
}) async {
  if (baseUrl.trim().isEmpty ||
      pollId.isEmpty ||
      deviceId.isEmpty ||
      options.isEmpty) {
    return false;
  }
  final owned = client == null;
  final agent = client ?? http.Client();
  try {
    final response = await agent
        .post(
          Uri.parse('${baseUrl.trim()}/v1/vote'),
          headers: const <String, String>{
            'Content-Type': 'application/json; charset=utf-8',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object>{
            'poll_id': pollId,
            'device_id': deviceId,
            'options': options,
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) return false;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map && decoded['ok'] == true;
  } catch (_) {
    return false;
  } finally {
    if (owned) agent.close();
  }
}
