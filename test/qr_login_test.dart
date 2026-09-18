import 'dart:convert';
import 'dart:io';

import 'package:bilicross/src/core/log_store.dart';
import 'package:bilicross/src/core/qr_login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假接口：/generate 固定返回，/poll 按脚本逐次返回。
/// 脚本写法 `"响应体|Set-Cookie 头"`，第二段可以为空。
class _FakeApi {
  _FakeApi({required this.pollScript, this.generateBody = _generateOk});

  static const String _generateOk =
      '{"code":0,"message":"OK","data":{"url":"https://account.bilibili.com/h5/auth?x=1",'
      '"qrcode_key":"KEY0123456789ABCDEF0123456789AB"}}';

  final List<String> pollScript;
  final String generateBody;
  int pollCount = 0;

  http.Client client() => MockClient((request) async {
        if (request.url.path.endsWith('/generate')) {
          return http.Response(
            generateBody,
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final index =
            pollCount < pollScript.length ? pollCount : pollScript.length - 1;
        pollCount += 1;
        final parts = pollScript[index].split('|');
        final headers = <String, String>{'content-type': 'application/json'};
        if (parts.length > 1 && parts[1].isNotEmpty) {
          headers['set-cookie'] = parts[1];
        }
        return http.Response(parts[0], 200, headers: headers);
      });
}

/// 只重写两个网络方法的假服务，用来驱动轮询器。
class _FakeService extends QrLoginService {
  _FakeService({required this.outcomes});

  static const QrLoginChallenge challenge = QrLoginChallenge(
    content: 'https://account.bilibili.com/h5/auth?x=1',
    key: 'KEY0123456789ABCDEF0123456789AB',
  );

  final List<QrPollOutcome> outcomes;
  int pollCalls = 0;

  @override
  Future<QrChallengeResult> requestQrCode() async =>
      const QrChallengeResult(
        stage: QrLoginStage.waitingScan,
        challenge: challenge,
      );

  @override
  Future<QrPollOutcome> pollOnce(String key) async {
    final index = pollCalls < outcomes.length ? pollCalls : outcomes.length - 1;
    pollCalls += 1;
    return outcomes[index];
  }
}

void main() {
  group('Cookie 提取', () {
    test('Set-Cookie 多条拼接时只按「, name=」切开，Expires 里的逗号不算分隔', () {
      final fields = QrLoginService.cookieFieldsFromHeaders(
        'SESSDATA=test-sess; Path=/; HttpOnly, '
        'bili_jct=test-jct; Path=/, '
        'DedeUserID=100000001; Expires=Wed, 01 Jan 2026 00:00:00 GMT; Path=/',
      );
      expect(fields['SESSDATA'], 'test-sess');
      expect(fields['bili_jct'], 'test-jct');
      expect(fields['DedeUserID'], '100000001');
      expect(fields.length, 3, reason: '属性不该被当成 Cookie');
    });

    test('crossDomain 地址上的查询参数能取出来', () {
      final fields = QrLoginService.queryFieldsOf(
        'https://passport.biligame.com/crossDomain?'
        'DedeUserID=100000001&DedeUserID__ckMd5=abc&SESSDATA=test-sess&bili_jct=test-jct',
      );
      expect(fields['SESSDATA'], 'test-sess');
      expect(fields['bili_jct'], 'test-jct');
      expect(fields['DedeUserID'], '100000001');
    });
  });

  group('取二维码', () {
    test('正常返回时给出内容与 key，状态为等待扫码', () async {
      final service = QrLoginService(client: _FakeApi(pollScript: const []).client());
      final result = await service.requestQrCode();
      expect(result.stage, QrLoginStage.waitingScan);
      expect(result.challenge, isNotNull);
      expect(result.challenge!.content, contains('account.bilibili.com'));
      expect(result.challenge!.key, isNotEmpty);
    });

    test('外层 code 非 0 视为接口不可用', () async {
      final service = QrLoginService(
        client: _FakeApi(
          pollScript: const [],
          generateBody: '{"code":-412,"message":"请求被拦截","data":null}',
        ).client(),
      );
      final result = await service.requestQrCode();
      expect(result.stage, QrLoginStage.unavailable);
      expect(result.challenge, isNull);
    });

    test('响应缺少 url 视为接口不可用', () async {
      final service = QrLoginService(
        client: _FakeApi(
          pollScript: const [],
          generateBody: '{"code":0,"data":{"qrcode_key":"k"}}',
        ).client(),
      );
      expect((await service.requestQrCode()).stage, QrLoginStage.unavailable);
    });

    test('响应不是 JSON 视为接口不可用', () async {
      final service = QrLoginService(
        client: _FakeApi(pollScript: const [], generateBody: '<html>403</html>').client(),
      );
      expect((await service.requestQrCode()).stage, QrLoginStage.unavailable);
    });

    test('网络异常归为网络错误', () async {
      final service = QrLoginService(
        client: MockClient((_) async => throw const SocketException('boom')),
      );
      expect((await service.requestQrCode()).stage, QrLoginStage.networkError);
    });
  });

  group('轮询状态解析', () {
    Future<QrPollOutcome> poll(int code) => QrLoginService(
          client: _FakeApi(pollScript: ['{"code":0,"data":{"code":$code}}']).client(),
        ).pollOnce('k');

    test('86101 等待扫码', () async {
      expect((await poll(QrLoginService.codeWaitingScan)).stage,
          QrLoginStage.waitingScan);
    });

    test('86090 已扫码等待确认', () async {
      expect((await poll(QrLoginService.codeWaitingConfirm)).stage,
          QrLoginStage.waitingConfirm);
    });

    test('86038 二维码已失效', () async {
      expect((await poll(QrLoginService.codeExpired)).stage, QrLoginStage.expired);
    });

    test('没见过的状态码归为接口不可用', () async {
      expect((await poll(86100)).stage, QrLoginStage.unavailable);
    });

    test('外层 code 非 0 归为接口不可用', () async {
      final service = QrLoginService(
        client: _FakeApi(pollScript: ['{"code":-509,"data":null}']).client(),
      );
      expect((await service.pollOnce('k')).stage, QrLoginStage.unavailable);
    });

    test('轮询遇网络异常归为网络错误', () async {
      final service = QrLoginService(
        client: MockClient((_) async => throw const SocketException('boom')),
      );
      expect((await service.pollOnce('k')).stage, QrLoginStage.networkError);
    });
  });

  group('成功时的 Cookie', () {
    const successBody =
        '{"code":0,"data":{"code":0,"url":"","refresh_token":"rt","timestamp":1}}';

    test('Cookie 走 Set-Cookie 响应头', () async {
      final service = QrLoginService(
        client: _FakeApi(pollScript: [
          '$successBody|SESSDATA=test-sess; Path=/; HttpOnly, '
              'bili_jct=test-jct; Path=/, DedeUserID=100000001; Path=/',
        ]).client(),
      );
      final outcome = await service.pollOnce('k');
      expect(outcome.stage, QrLoginStage.success);
      expect(outcome.cookie, isNotNull);
      expect(outcome.cookie!.isComplete, isTrue);
      // raw 是给 AppState.applyCookieText 用的规范串。
      expect(outcome.cookie!.raw, contains('SESSDATA=test-sess'));
      expect(outcome.cookie!.raw, contains('bili_jct=test-jct'));
      expect(outcome.cookie!.raw, contains('DedeUserID=100000001'));
    });

    test('Cookie 走 crossDomain 跳转地址的参数', () async {
      final body = jsonEncode({
        'code': 0,
        'data': {
          'code': 0,
          'url': 'https://passport.biligame.com/crossDomain?'
              'DedeUserID=100000001&DedeUserID__ckMd5=abc&'
              'SESSDATA=test-sess&bili_jct=test-jct',
          'refresh_token': 'rt',
        },
      });
      final service = QrLoginService(
        client: _FakeApi(pollScript: [body]).client(),
      );
      final outcome = await service.pollOnce('k');
      expect(outcome.stage, QrLoginStage.success);
      expect(outcome.cookie!.dedeUserId, '100000001');
    });

    test('缺少 DedeUserID 时明确报出缺哪个字段', () async {
      final service = QrLoginService(
        client: _FakeApi(pollScript: [
          '$successBody|SESSDATA=test-sess; Path=/, bili_jct=test-jct; Path=/',
        ]).client(),
      );
      final outcome = await service.pollOnce('k');
      expect(outcome.stage, QrLoginStage.unavailable);
      expect(outcome.cookie, isNull);
      expect(outcome.missingFields, ['DedeUserID']);
    });

    test('缺少 SESSDATA 时同样不当作成功', () async {
      final service = QrLoginService(
        client: _FakeApi(pollScript: [
          '$successBody|bili_jct=test-jct; Path=/, DedeUserID=100000001; Path=/',
        ]).client(),
      );
      final outcome = await service.pollOnce('k');
      expect(outcome.stage, QrLoginStage.unavailable);
      expect(outcome.missingFields, ['SESSDATA']);
    });

    test('成功但没有带回任何 Cookie 时归为接口不可用', () async {
      final service = QrLoginService(
        client: _FakeApi(pollScript: [successBody]).client(),
      );
      final outcome = await service.pollOnce('k');
      expect(outcome.stage, QrLoginStage.unavailable);
      expect(outcome.cookie, isNull);
    });
  });

  group('轮询器', () {
    test('状态依次推进：取码中 → 等待扫码 → 已扫码 → 失效', () async {
      final service = _FakeService(
        outcomes: [
          const QrPollOutcome(QrLoginStage.waitingScan),
          const QrPollOutcome(QrLoginStage.waitingConfirm),
          const QrPollOutcome(QrLoginStage.expired),
        ],
      );
      final poller = QrLoginPoller(
        service: service,
        interval: const Duration(milliseconds: 5),
        deadline: const Duration(seconds: 2),
      );
      final seen = <QrLoginStage>[];
      final sub = poller.updates.listen((update) => seen.add(update.stage));
      await poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // 第一个事件是取码中（refresh 里先发 loading 再请求二维码）。
      expect(seen.first, QrLoginStage.loading);
      expect(seen, contains(QrLoginStage.waitingScan));
      expect(seen, contains(QrLoginStage.waitingConfirm));
      expect(seen.last, QrLoginStage.expired);
      expect(poller.current.stage, QrLoginStage.expired);
      await sub.cancel();
      poller.dispose();
    });

    test('取消之后停在已取消，不再轮询', () async {
      final service = _FakeService(
        outcomes: [const QrPollOutcome(QrLoginStage.waitingScan)],
      );
      final poller = QrLoginPoller(
        service: service,
        interval: const Duration(milliseconds: 5),
        deadline: const Duration(seconds: 2),
      );
      await poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      poller.cancel();
      final callsAfterCancel = service.pollCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(poller.current.stage, QrLoginStage.canceled);
      expect(service.pollCalls, callsAfterCancel, reason: '取消后不该再发请求');
      poller.dispose();
    });

    test('超过期限就报超时', () async {
      final service = _FakeService(
        outcomes: [const QrPollOutcome(QrLoginStage.waitingScan)],
      );
      final poller = QrLoginPoller(
        service: service,
        interval: const Duration(milliseconds: 5),
        deadline: const Duration(milliseconds: 1),
      );
      await poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(poller.current.stage, QrLoginStage.timeout);
      poller.dispose();
    });

    test('连续网络失败到阈值后停下来', () async {
      final service = _FakeService(
        outcomes: [const QrPollOutcome(QrLoginStage.networkError)],
      );
      final poller = QrLoginPoller(
        service: service,
        interval: const Duration(milliseconds: 5),
        deadline: const Duration(seconds: 5),
        maxConsecutiveFailures: 3,
      );
      await poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(poller.current.stage, QrLoginStage.networkError);
      expect(service.pollCalls, 3);
      poller.dispose();
    });

    test('销毁后不再轮询', () async {
      final service = _FakeService(
        outcomes: [const QrPollOutcome(QrLoginStage.waitingScan)],
      );
      final poller = QrLoginPoller(
        service: service,
        interval: const Duration(milliseconds: 5),
        deadline: const Duration(seconds: 5),
      );
      await poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      poller.dispose();
      final callsAfterDispose = service.pollCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.pollCalls, callsAfterDispose);
    });
  });

  group('安全与兜底', () {
    test('日志里不出现二维码 key、Cookie 值与 token', () async {
      LogStore.instance.clear();
      const key = 'KEY0123456789ABCDEF0123456789AB';
      final service = QrLoginService(
        client: _FakeApi(pollScript: [
          '{"code":0,"data":{"code":0,"url":"","refresh_token":"rt-secret"}}'
              '|SESSDATA=test-sess; Path=/, bili_jct=test-jct; Path=/, '
              'DedeUserID=100000001; Path=/',
        ]).client(),
      );
      final poller = QrLoginPoller(
        service: service,
        interval: const Duration(milliseconds: 5),
        deadline: const Duration(seconds: 2),
      );
      await poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      poller.dispose();
      final log = LogStore.instance.dump;
      expect(log, isNotEmpty, reason: '至少要有状态日志');
      expect(log.contains(key), isFalse, reason: 'key 不能进日志');
      expect(log.contains('test-sess'), isFalse, reason: 'Cookie 值不能进日志');
      expect(log.contains('test-jct'), isFalse);
      expect(log.contains('rt-secret'), isFalse, reason: 'refresh_token 不能进日志');
    });

    test('扫码失败不阻塞账号页：两个入口与原有 Cookie 链路都还在', () {
      final source = File('lib/src/ui/account_page.dart').readAsStringSync();
      expect(source, contains("l10n.tr('qr.entry')"), reason: '扫码入口');
      expect(source, contains("l10n.tr('account.webLogin')"), reason: '网页登录兜底');
      expect(source, contains("l10n.tr('account.pasteCookie')"), reason: '粘贴兜底');
      expect(source, contains("l10n.tr('account.importCookie')"), reason: '导入兜底');
      expect(source, contains('applyCookieText'), reason: '复用原有保存与校验');
    });

    test('扫码卡片自己不带存储：不写凭据、不碰 Store', () {
      final source = File('lib/src/core/qr_login.dart').readAsStringSync();
      expect(source.contains('saveCredentials'), isFalse);
      expect(source.contains('CredentialBundle'), isFalse);
      expect(source.contains('LogStore.instance.add'), isTrue);
      // 日志只写状态名，不把变量插进日志。
      for (final line in source.split('\n')) {
        if (line.contains('LogStore.instance.add')) {
          expect(line.contains(r'$'), isFalse, reason: '日志不要插值：$line');
        }
      }
    });
  });
}
