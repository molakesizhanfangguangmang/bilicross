import 'dart:convert';

import 'package:http/http.dart' as http;

import 'announcement.dart';

/// 一次反馈提交的结局。
enum FeedbackStatus {
  /// 服务端收下了。
  accepted,

  /// 票据被拒（过期、用过、换了网络出口），可重试。
  nonceInvalid,

  /// 网络或服务端异常，结果未知。
  failed,
}

/// 提交一条用户建议。正文必填、联系方式选填；服务端负责限流与长度截断。
Future<FeedbackStatus> submitFeedback({
  required String deviceId,
  required String text,
  String contact = '',
  String deviceKey = '',
  String nonce = '',
  Map<String, Object>? deviceInfo,
  String pkg = '',
  http.Client? client,
  String baseUrl = kAnnouncementsBaseUrl,
  Duration timeout = kAnnouncementTimeout,
}) async {
  if (baseUrl.trim().isEmpty || deviceId.isEmpty || text.trim().isEmpty) {
    return FeedbackStatus.failed;
  }
  final owned = client == null;
  final agent = client ?? http.Client();
  try {
    final response = await agent
        .post(
          Uri.parse('${baseUrl.trim()}/v1/feedback'),
          headers: const <String, String>{
            'Content-Type': 'application/json; charset=utf-8',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object>{
            'device_id': deviceId,
            'text': text,
            if (contact.isNotEmpty) 'contact': contact,
            if (deviceKey.isNotEmpty) 'device_key': deviceKey,
            if (nonce.isNotEmpty) 'nonce': nonce,
            if (deviceInfo != null && deviceInfo.isNotEmpty)
              'device_info': deviceInfo,
            if (pkg.isNotEmpty) 'pkg': pkg,
          }),
        )
        .timeout(timeout);
    if (response.statusCode == 200) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map && decoded['ok'] == true
          ? FeedbackStatus.accepted
          : FeedbackStatus.failed;
    }
    if (response.statusCode == 403) {
      return _feedbackErrorOf(response) == 'nonce_invalid'
          ? FeedbackStatus.nonceInvalid
          : FeedbackStatus.failed;
    }
    return FeedbackStatus.failed;
  } catch (_) {
    return FeedbackStatus.failed;
  } finally {
    if (owned) agent.close();
  }
}

String _feedbackErrorOf(http.Response response) {
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) return '${decoded['error'] ?? ''}';
  } catch (_) {
    // 非 JSON 的错误页：按普通失败处理。
  }
  return '';
}
