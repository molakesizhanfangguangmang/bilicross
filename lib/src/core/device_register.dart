import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 内测设备登记：首次启动上报一次，失败每分钟重试直到成功；
/// 之后每次启动刷新一次最近时间。
///
/// 只服务内测包（`.test`），正式包不调用。
class DeviceRegistrar {
  DeviceRegistrar({
    required this.deviceId,
    required this.deviceKey,
    required this.deviceInfo,
    required this.pkg,
    this.baseUrl = 'https://bili.culture-see.de5.net',
    this.retryInterval = const Duration(minutes: 1),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String deviceId;
  final String deviceKey;
  final Map<String, Object> deviceInfo;
  final String pkg;
  final String baseUrl;
  final Duration retryInterval;
  final http.Client _client;

  Timer? _retryTimer;
  bool _disposed = false;

  /// 立即上报一次；失败就按 [retryInterval] 排下一次，直到成功或 dispose。
  Future<bool> report() async {
    if (_disposed) return false;
    final ok = await _send();
    if (!ok && !_disposed) {
      _retryTimer?.cancel();
      _retryTimer = Timer(retryInterval, () => report());
    }
    return ok;
  }

  Future<bool> _send() async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/v1/device'),
            headers: const <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, Object>{
              'device_id': deviceId,
              if (deviceKey.isNotEmpty) 'device_key': deviceKey,
              if (deviceInfo.isNotEmpty) 'device_info': deviceInfo,
              if (pkg.isNotEmpty) 'pkg': pkg,
            }),
          )
          .timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _client.close();
  }
}
