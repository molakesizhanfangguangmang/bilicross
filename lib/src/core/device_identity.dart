import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// 指纹盐。⚠️ 它随包公开，**不是秘密** —— 加盐只为了让上报值不等于系统原始标识，
/// 真要防的是「服务端库里存明文设备号」这件事，不是防逆向。
const String kDeviceKeySalt = 'bilicross/device-key/v1';

/// 系统给不出可信标识时返回的那些占位值。
const Set<String> _placeholderIds = <String>{
  '',
  'unknown',
  'null',
  '0', // 部分 ROM 会给出全 0
  '0000000000000000',
  '9774d56d682e549c', // Android 2.2 时代所有机器共用的坏 ANDROID_ID
};

/// 一台机器的身份：一枚去重用的指纹 + 一份设备画像。
class DeviceIdentity {
  const DeviceIdentity._(this.key, this.info);

  /// 服务端按它做「一机一票」的去重主键。
  ///
  /// 空串＝没拿到系统标识，服务端届时回落到安装内的随机 `device_id`。
  final String key;

  /// 一并上报的设备画像（型号 / ABI / 构建指纹），供服务端标出模拟器嫌疑。
  /// 只含机型与构建字段，**不含用户名、序列号、账号**。
  final Map<String, Object> info;

  static const DeviceIdentity unknown = DeviceIdentity._('', <String, Object>{});
}

/// 取本机身份。任何异常都收敛成 [DeviceIdentity.unknown]，不往外抛 ——
/// 拿不到指纹只影响去重强度，不该让投票这件事本身失败。
Future<DeviceIdentity> collectDeviceIdentity({DeviceInfoPlugin? plugin}) async {
  try {
    final device = plugin ?? DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await device.androidInfo;
      return DeviceIdentity._(hashDeviceId(android.id), <String, Object>{
        'platform': 'android',
        'abis': android.supportedAbis,
        'model': android.model,
        'manufacturer': android.manufacturer,
        'brand': android.brand,
        'device': android.device,
        'hardware': android.hardware,
        'fingerprint': android.fingerprint,
        'physical': android.isPhysicalDevice,
      });
    }
    if (Platform.isWindows) {
      final windows = await device.windowsInfo;
      return DeviceIdentity._(hashDeviceId(windows.deviceId), <String, Object>{
        'platform': 'windows',
        'model': windows.productName,
        'manufacturer': 'Windows',
      });
    }
    return DeviceIdentity.unknown;
  } catch (_) {
    // 通道不可用（测试宿主、异常 ROM）不是错误。
    return DeviceIdentity.unknown;
  }
}

/// `sha256(原始标识 + 盐)` 的十六进制；原始标识不可信时给空串。
String hashDeviceId(String raw) {
  final value = raw.trim();
  if (_placeholderIds.contains(value.toLowerCase())) return '';
  return sha256.convert(utf8.encode('$value|$kDeviceKeySalt')).toString();
}
