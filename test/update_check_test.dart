import 'dart:convert';

import 'package:bilicross/src/core/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _release(String tag, {String? url, int status = 200}) {
  final body = jsonEncode(<String, Object?>{
    'tag_name': tag,
    'html_url': ?url,
    'name': tag,
  });
  return http.Response(body, status, headers: <String, String>{
    'content-type': 'application/json; charset=utf-8',
  });
}

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

  test('Release 响应取 version 与页面地址', () {
    final parsed = readLatestRelease(<String, Object?>{
      'tag_name': 'v1.0.2',
      'html_url': 'https://example.com/rel',
    });
    expect(parsed?['version'], 'v1.0.2');
    expect(parsed?['url'], 'https://example.com/rel');
    expect(readLatestRelease(null), isNull);
    expect(readLatestRelease(<String, Object?>{'name': 'v1'}), isNull);
    expect(readLatestRelease(<String, Object?>{'tag_name': '  '}), isNull);
  });

  test('有新版时给出确认框要用的信息', () {
    final result = resultFromRelease(<String, Object?>{'tag_name': '1.0.2'}, '1.0.1');
    expect(result.outcome, UpdateOutcome.available);
    expect(result.latestLabel, 'v1.0.2');
    expect(result.releaseUrl, kReleaseListUrl);

    final same = resultFromRelease(<String, Object?>{'tag_name': 'v1.0.1'}, '1.0.1');
    expect(same.outcome, UpdateOutcome.upToDate);

    final broken = resultFromRelease(<String, Object?>{}, '1.0.1');
    expect(broken.outcome, UpdateOutcome.failed);
  });

  test('网络层：有新版的响应', () async {
    final client = MockClient((request) async {
      expect(request.headers['User-Agent'], 'Yigui/1.0.1');
      expect(request.url.host, 'api.github.com');
      return _release('v1.0.2', url: 'https://example.com/v1.0.2');
    });
    final result = await checkForUpdate(client: client, currentVersion: '1.0.1');
    expect(result.outcome, UpdateOutcome.available);
    expect(result.latestVersion, 'v1.0.2');
    expect(result.releaseUrl, 'https://example.com/v1.0.2');
    expect(result.currentVersion, '1.0.1');
  });

  test('网络层：已是最新', () async {
    final client = MockClient((request) async => _release('v1.0.1'));
    final result = await checkForUpdate(client: client, currentVersion: '1.0.1');
    expect(result.outcome, UpdateOutcome.upToDate);
  });

  test('网络层：接口出错或连不上都算检测失败', () async {
    final server = MockClient((request) async => _release('v1.0.2', status: 500));
    expect(
      (await checkForUpdate(client: server, currentVersion: '1.0.1')).outcome,
      UpdateOutcome.failed,
    );

    final down = MockClient((request) async => throw const SocketFailure());
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
      return _release('v1.0.2');
    });
    final result = await checkForUpdate(client: client, currentVersion: '');
    expect(called, isFalse);
    expect(result.outcome, UpdateOutcome.failed);
  });
}

class SocketFailure implements Exception {
  const SocketFailure();
}
