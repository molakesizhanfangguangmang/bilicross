import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'announcement.dart';

/// 一次提交的结局。需要区分「票据不对」与「真失败」—— 前者重领一张就能过，
/// 后者再试也是白试。
enum VoteStatus {
  /// 服务端收下了。
  accepted,

  /// 服务端明确拒绝（选项非法 / 投票已关 / 已经投过）。
  rejected,

  /// 票据被拒：过期、用过、换了网络出口。重领一张再试一次。
  nonceInvalid,

  /// 网络或服务端异常，结果未知。
  failed,
}

/// 生成一个设备标识：16 字节随机数的十六进制。
///
/// ⚠️ 这是**安装内**的随机号，清数据或重装就换新的。真正用于「一机一票」去重的
/// 是 [submitVote] 带来的 `device_key`（系统标识的哈希）；这一枚只在拿不到系统
/// 标识时兜底。
String newDeviceId([Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 提交一票。网络异常、服务端拒绝都收敛成 [VoteStatus]，不往外抛。
///
/// ⚠️ 单选**不给改票入口**：界面投完即固定，这里的 options 只会提交一次。
Future<VoteStatus> submitVote({
  required String pollId,
  required String deviceId,
  required List<String> options,
  String deviceKey = '',
  String nonce = '',
  Map<String, Object>? deviceInfo,
  String pkg = '',
  http.Client? client,
  String baseUrl = kAnnouncementsBaseUrl,
  Duration timeout = kAnnouncementTimeout,
}) async {
  if (baseUrl.trim().isEmpty ||
      pollId.isEmpty ||
      deviceId.isEmpty ||
      options.isEmpty) {
    return VoteStatus.failed;
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
            if (deviceKey.isNotEmpty) 'device_key': deviceKey,
            if (nonce.isNotEmpty) 'nonce': nonce,
            if (deviceInfo != null && deviceInfo.isNotEmpty)
              'device_info': deviceInfo,
            if (pkg.isNotEmpty) 'pkg': pkg,
            'options': options,
          }),
        )
        .timeout(timeout);
    if (response.statusCode == 200) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map && decoded['ok'] == true
          ? VoteStatus.accepted
          : VoteStatus.rejected;
    }
    if (response.statusCode == 403) {
      return _errorOf(response) == 'nonce_invalid'
          ? VoteStatus.nonceInvalid
          : VoteStatus.rejected;
    }
    return VoteStatus.failed;
  } catch (_) {
    return VoteStatus.failed;
  } finally {
    if (owned) agent.close();
  }
}

String _errorOf(http.Response response) {
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) return '${decoded['error'] ?? ''}';
  } catch (_) {
    // 非 JSON 的错误页：按普通拒绝处理。
  }
  return '';
}
