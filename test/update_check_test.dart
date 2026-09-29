import 'dart:convert';

import 'package:bilicross/src/core/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _update(Object? update, {int status = 200}) {
  return http.Response(
    jsonEncode(<String, Object?>{'ok': true, 'update': update}),
    status,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

Map<String, Object?> _config({
  String version = '1.0.2',
  String notes = '',
  String androidUrl = '',
  String windowsSetupUrl = '',
  String windowsPortableUrl = '',
  String minVersion = '',
}) =>
    <String, Object?>{
      'version': version,
      'notes': notes,
      'androidUrl': androidUrl,
      'windowsSetupUrl': windowsSetupUrl,
      'windowsPortableUrl': windowsPortableUrl,
      'minVersion': minVersion,
    };

void main() {
  test('版本号解析：去前缀，丢构建号与预发布后缀', () {
    expect(parseVersionNumbers('v1.0.1'), <int>[1, 0, 1]);
    expect(parseVersionNumbers('1.0.1+11'), <int>[1, 0, 1]);
    expect(parseVersionNumbers('v1.2.0-beta.1'), <int>[1, 2, 0]);
    expect(parseVersionNumbers(' 1.4 '), <int>[1, 4]);
    expect(parseVersionNumbers('unknown'), isEmpty);
    expect(parseVersionNumbers(''), isEmpty);
  });

  test('只有远端更高才算有新版', () {
    expect(isRemoteNewer('v1.0.1', '1.0.0'), isTrue);
    expect(isRemoteNewer('v1.1.0', '1.0.9'), isTrue);
    expect(isRemoteNewer('v1.0.0.1', '1.0.0'), isTrue);
    expect(isRemoteNewer('v1.0.1', '1.0.1'), isFalse);
    expect(isRemoteNewer('v1.0', '1.0.0'), isFalse);
    expect(isRemoteNewer('v1.0.0', '1.0.1'), isFalse);
    expect(isRemoteNewer('unknown', '1.0.1'), isFalse);
    expect(isRemoteNewer('v1.0.1', ''), isFalse);
  });

  test('产物 digest 归一化成小写十六进制', () {
    expect(normalizeChecksum(null), '');
    expect(normalizeChecksum('nope'), '');
    expect(
      normalizeChecksum('sha256:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'),
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
    expect(
      normalizeChecksum('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'),
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
  });

  test('产物列表带上 digest 作为 sha256', () {
    final assets = readReleaseAssets(<String, Object?>{
      'assets': <Object?>[
        <String, Object?>{
          'name': 'BiliCross-1.0.0-android-arm64.apk',
          'browser_download_url': 'https://example.com/a.apk',
          'size': 123,
          'digest': 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        },
      ],
    });
    expect(
      assets.single.sha256,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );
  });

  test('更新配置折算成检查结果：新版、已最新、坏响应', () {
    final newer = resultFromUpdateConfig(
      <String, Object?>{'update': _config(version: '1.0.2')},
      '1.0.1',
    );
    expect(newer.outcome, UpdateOutcome.available);
    expect(newer.latestLabel, 'v1.0.2');

    final same = resultFromUpdateConfig(
      <String, Object?>{'update': _config(version: '1.0.1')},
      '1.0.1',
    );
    expect(same.outcome, UpdateOutcome.upToDate);

    final broken = resultFromUpdateConfig(<String, Object?>{}, '1.0.1');
    expect(broken.outcome, UpdateOutcome.failed);
  });

  test('低于 minVersion 时强制更新', () {
    final forced = resultFromUpdateConfig(
      <String, Object?>{
        'update': _config(version: '2.3.4', minVersion: '2.3.4'),
      },
      '2.3.3',
    );
    expect(forced.outcome, UpdateOutcome.available);
    expect(forced.forceUpdate, isTrue);

    final optional = resultFromUpdateConfig(
      <String, Object?>{
        'update': _config(version: '2.3.4', minVersion: '2.3.4'),
      },
      '2.3.4',
    );
    expect(optional.forceUpdate, isFalse);
  });

  test('网络层：从服务端拿到新版', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'bili.culture-see.de5.net');
      expect(request.url.path, '/v1/update');
      return _update(
        _config(version: '1.0.2', androidUrl: 'https://example.com/a.apk'),
      );
    });
    final result = await checkForUpdate(client: client, currentVersion: '1.0.1');
    expect(result.outcome, UpdateOutcome.available);
    expect(result.latestVersion, '1.0.2');
    expect(result.assets.single.downloadUrl, 'https://example.com/a.apk');
    expect(result.currentVersion, '1.0.1');
  });

  test('网络层：已是最新', () async {
    final client = MockClient(
      (request) async => _update(_config(version: '1.0.1')),
    );
    final result = await checkForUpdate(client: client, currentVersion: '1.0.1');
    expect(result.outcome, UpdateOutcome.upToDate);
  });

  test('网络层：接口出错或连不上都算检测失败', () async {
    final server = MockClient(
      (request) async => _update(_config(), status: 500),
    );
    expect(
      (await checkForUpdate(client: server, currentVersion: '1.0.1')).outcome,
      UpdateOutcome.failed,
    );

    final down = MockClient(
      (request) async => throw const SocketFailure(),
    );
    expect(
      (await checkForUpdate(client: down, currentVersion: '1.0.1')).outcome,
      UpdateOutcome.failed,
    );

    final notJson = MockClient((request) async => http.Response('nope', 200));
    expect(
      (await checkForUpdate(client: notJson, currentVersion: '1.0.1')).outcome,
      UpdateOutcome.failed,
    );
  });

  test('网络层：读不到本地版本号就不发请求', () async {
    var called = false;
    final client = MockClient((request) async {
      called = true;
      return _update(_config());
    });
    final result = await checkForUpdate(client: client, currentVersion: '');
    expect(called, isFalse);
    expect(result.outcome, UpdateOutcome.failed);
  });
}

class SocketFailure implements Exception {
  const SocketFailure();
}
