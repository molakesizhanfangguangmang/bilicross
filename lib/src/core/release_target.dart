import 'dart:io';

import 'distribution.dart';
import 'update_check.dart';

/// 本机运行的 CPU 架构。只区分项目会发包的两种，其余归入 [unknown]。
enum CpuArch { x64, arm64, unknown }

/// 从环境变量判本机架构。
///
/// Windows 上 `PROCESSOR_ARCHITECTURE` 是进程看到的架构；32 位进程跑在 64 位系统时
/// 该值会是 `x86`，真实架构在 `PROCESSOR_ARCHITEW6432`，所以后者优先。
CpuArch archFromEnvironment(Map<String, String> env) {
  final native = (env['PROCESSOR_ARCHITEW6432'] ?? '').trim().toUpperCase();
  final primary = (env['PROCESSOR_ARCHITECTURE'] ?? '').trim().toUpperCase();
  final value = native.isNotEmpty ? native : primary;
  switch (value) {
    case 'AMD64':
    case 'X64':
      return CpuArch.x64;
    case 'ARM64':
      return CpuArch.arm64;
    default:
      return CpuArch.unknown;
  }
}

/// Android 的 ABI 名（`arm64-v8a` 等）折算成 [CpuArch]。
CpuArch archFromAbiName(String abi) {
  final value = abi.trim().toLowerCase();
  if (value.startsWith('arm64') || value == 'aarch64') return CpuArch.arm64;
  if (value.startsWith('x86_64') || value.startsWith('x64')) return CpuArch.x64;
  return CpuArch.unknown;
}

/// 本机该用哪个产物。
///
/// 先按平台与架构缩小范围，Windows 再按发行通道挑安装包或便携包。
/// [channel] 用 [distribution.dart] 的判定结果，避免这里重复一套逻辑。
ReleaseAsset? pickAssetFor({
  required List<ReleaseAsset> assets,
  required bool isWindows,
  required bool isAndroid,
  required ReleaseChannel channel,
  required CpuArch arch,
}) {
  // 校验文件不参与下载。
  final usable = assets.where((a) => !a.isChecksum).toList();
  if (usable.isEmpty) return null;

  if (isAndroid) {
    // 只发 arm64 的 apk。
    // 规范名是 `BiliCross-<版本>-android-arm64.apk`；
    // 1.0.6 及更早用的是 gradle 默认名 `app-release.apk`，一并认下，
    // 否则老版本的用户点「下载」会匹配不到。
    final named = _firstMatch(
      usable,
      (n) => n.contains('android') && n.contains('arm64') && n.endsWith('.apk'),
    );
    if (named != null) return named;
    return _firstMatch(usable, (n) => n == 'app-release.apk');
  }

  if (isWindows) {
    final archToken = switch (arch) {
      CpuArch.arm64 => 'arm64',
      CpuArch.x64 => 'x64',
      CpuArch.unknown => '',
    };
    final channelToken = channel == ReleaseChannel.portable
        ? 'portable'
        : 'setup';
    // 先按「windows + 架构 + 通道」精确匹配。
    final exact = _firstMatch(
      usable,
      (n) =>
          n.contains('windows') &&
          n.contains(channelToken) &&
          (archToken.isEmpty || n.contains(archToken)),
    );
    if (exact != null) return exact;
    // 架构对不上（例如 ARM64 尚无对应包）时只退一步：同通道的 x64 包。
    if (archToken.isNotEmpty && archToken != 'x64') {
      return _firstMatch(
        usable,
        (n) =>
            n.contains('windows') && n.contains(channelToken) && n.contains('x64'),
      );
    }
    return null;
  }

  return null;
}

/// 在产物名里找第一个满足条件的；名字统一转小写比较，避免大小写差异漏匹配。
ReleaseAsset? _firstMatch(
  List<ReleaseAsset> assets,
  bool Function(String lowerName) test,
) {
  for (final asset in assets) {
    if (test(asset.name.toLowerCase())) return asset;
  }
  return null;
}

/// 按当前运行环境推断架构。
///
/// Windows 读环境变量；Android 在真机上应当由调用方传入 [abiName]
/// （来自 `Abi.current()`），因为 `Platform.environment` 在 Android 上拿不到 ABI。
CpuArch currentArch({Map<String, String>? environment, String? abiName}) {
  if (abiName != null && abiName.isNotEmpty) return archFromAbiName(abiName);
  if (Platform.isAndroid) return CpuArch.unknown;
  return archFromEnvironment(environment ?? Platform.environment);
}
