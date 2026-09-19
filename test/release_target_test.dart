import 'package:bilicross/src/core/distribution.dart';
import 'package:bilicross/src/core/release_target.dart';
import 'package:bilicross/src/core/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

ReleaseAsset _asset(String name) =>
    ReleaseAsset(name: name, downloadUrl: 'https://example.com/$name');

/// 贴近真实 Release 的产物集合（1.0.6 的命名）。
List<ReleaseAsset> _realWorldAssets() => <ReleaseAsset>[
      _asset('BiliCross-windows-x64-setup.exe'),
      _asset('BiliCross-windows-x64-setup.exe.sha256'),
      _asset('BiliCross-windows-x64-portable.zip'),
      _asset('BiliCross-windows-x64-portable.zip.sha256'),
      _asset('BiliCross-1.0.6-android-arm64.apk'),
      _asset('BiliCross-1.0.6-android-arm64.apk.sha256'),
    ];

void main() {
  group('架构判定', () {
    test('Windows 环境变量映射到架构', () {
      expect(
        archFromEnvironment(const {'PROCESSOR_ARCHITECTURE': 'AMD64'}),
        CpuArch.x64,
      );
      expect(
        archFromEnvironment(const {'PROCESSOR_ARCHITECTURE': 'ARM64'}),
        CpuArch.arm64,
      );
      expect(
        archFromEnvironment(const {'PROCESSOR_ARCHITECTURE': 'x86'}),
        CpuArch.unknown,
      );
    });

    test('32 位进程跑在 64 位系统上时以 ARCHITEW6432 为准', () {
      expect(
        archFromEnvironment(const {
          'PROCESSOR_ARCHITECTURE': 'x86',
          'PROCESSOR_ARCHITEW6432': 'AMD64',
        }),
        CpuArch.x64,
      );
    });

    test('Android ABI 名映射', () {
      expect(archFromAbiName('arm64-v8a'), CpuArch.arm64);
      expect(archFromAbiName('x86_64'), CpuArch.x64);
      expect(archFromAbiName('armeabi-v7a'), CpuArch.unknown);
    });

    test('传了 abiName 时优先于环境变量', () {
      expect(
        currentArch(
          environment: const {'PROCESSOR_ARCHITECTURE': 'AMD64'},
          abiName: 'arm64-v8a',
        ),
        CpuArch.arm64,
      );
    });
  });

  group('产物选择', () {
    test('Windows 安装版 + x64 → setup.exe', () {
      final picked = pickAssetFor(
        assets: _realWorldAssets(),
        isWindows: true,
        isAndroid: false,
        channel: ReleaseChannel.installed,
        arch: CpuArch.x64,
      );
      expect(picked?.name, 'BiliCross-windows-x64-setup.exe');
    });

    test('Windows 便携版 + x64 → portable.zip', () {
      final picked = pickAssetFor(
        assets: _realWorldAssets(),
        isWindows: true,
        isAndroid: false,
        channel: ReleaseChannel.portable,
        arch: CpuArch.x64,
      );
      expect(picked?.name, 'BiliCross-windows-x64-portable.zip');
    });

    test('Android 只取 arm64 的 apk', () {
      final picked = pickAssetFor(
        assets: _realWorldAssets(),
        isWindows: false,
        isAndroid: true,
        channel: ReleaseChannel.installed,
        arch: CpuArch.arm64,
      );
      expect(picked?.name, 'BiliCross-1.0.6-android-arm64.apk');
    });

    test('Android 认 1.0.6 及更早的默认产物名 app-release.apk', () {
      // 1.0.6 的 Release 里 apk 就叫这个名字，用户点「下载」要能拿到。
      final picked = pickAssetFor(
        assets: <ReleaseAsset>[
          _asset('app-release.apk'),
          _asset('app-release.apk.sha256'),
        ],
        isWindows: false,
        isAndroid: true,
        channel: ReleaseChannel.installed,
        arch: CpuArch.arm64,
      );
      expect(picked?.name, 'app-release.apk');
    });

    test('Android 规范名优先于默认名', () {
      final picked = pickAssetFor(
        assets: <ReleaseAsset>[
          _asset('app-release.apk'),
          _asset('BiliCross-1.0.7-android-arm64.apk'),
        ],
        isWindows: false,
        isAndroid: true,
        channel: ReleaseChannel.installed,
        arch: CpuArch.arm64,
      );
      expect(picked?.name, 'BiliCross-1.0.7-android-arm64.apk');
    });

    test('Android 不把非 apk 文件当下载目标', () {
      final picked = pickAssetFor(
        assets: <ReleaseAsset>[_asset('BiliCross-1.0.6-android-arm64.zip')],
        isWindows: false,
        isAndroid: true,
        channel: ReleaseChannel.installed,
        arch: CpuArch.arm64,
      );
      expect(picked, isNull);
    });

    test('不会挑中 .sha256 校验文件', () {
      for (final channel in ReleaseChannel.values) {
        final picked = pickAssetFor(
          assets: _realWorldAssets(),
          isWindows: true,
          isAndroid: false,
          channel: channel,
          arch: CpuArch.x64,
        );
        expect(picked?.isChecksum, isFalse, reason: '$channel');
      }
    });

    test('ARM64 尚无对应包时退回同通道的 x64 包', () {
      final picked = pickAssetFor(
        assets: _realWorldAssets(),
        isWindows: true,
        isAndroid: false,
        channel: ReleaseChannel.portable,
        arch: CpuArch.arm64,
      );
      expect(picked?.name, 'BiliCross-windows-x64-portable.zip');
    });

    test('通道对不上时不乱退：便携版用户拿不到 setup.exe', () {
      final picked = pickAssetFor(
        assets: _realWorldAssets(),
        isWindows: true,
        isAndroid: false,
        channel: ReleaseChannel.portable,
        arch: CpuArch.arm64,
      );
      expect(picked?.name.contains('setup'), isFalse);
    });

    test('没有匹配产物时返回 null（调用方退 Release 页）', () {
      final picked = pickAssetFor(
        assets: <ReleaseAsset>[_asset('BiliCross-linux-x64.tar.gz')],
        isWindows: true,
        isAndroid: false,
        channel: ReleaseChannel.installed,
        arch: CpuArch.x64,
      );
      expect(picked, isNull);
    });

    test('产物列表为空时返回 null', () {
      expect(
        pickAssetFor(
          assets: const <ReleaseAsset>[],
          isWindows: true,
          isAndroid: false,
          channel: ReleaseChannel.installed,
          arch: CpuArch.x64,
        ),
        isNull,
      );
    });

    test('名字大小写不同也能匹配', () {
      final picked = pickAssetFor(
        assets: <ReleaseAsset>[_asset('BiliCross-Windows-X64-Setup.EXE')],
        isWindows: true,
        isAndroid: false,
        channel: ReleaseChannel.installed,
        arch: CpuArch.x64,
      );
      expect(picked?.name, 'BiliCross-Windows-X64-Setup.EXE');
    });
  });
}
