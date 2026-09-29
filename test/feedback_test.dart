import 'dart:convert';

import 'package:bilicross/src/core/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? payload, [int status = 200]) => http.Response(
      jsonEncode(payload),
      status,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

void main() {
  group('提交建议', () {
    test('成功提交：正文与联系方式原样上报', () async {
      late Map<String, dynamic> received;
      final client = MockClient((request) async {
        received = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(<String, Object?>{'ok': true});
      });

      final status = await submitFeedback(
        deviceId: 'd1',
        text: '加个夜间模式',
        contact: 'qq 123',
        deviceKey: 'k1',
        nonce: 'n1',
        pkg: 'io.github.molakesizhanfangguangmang.biliharbor.test',
        client: client,
      );

      expect(status, FeedbackStatus.accepted);
      expect(received['device_id'], 'd1');
      expect(received['text'], '加个夜间模式');
      expect(received['contact'], 'qq 123');
      expect(received['device_key'], 'k1');
      expect(received['nonce'], 'n1');
      expect(received['pkg'], 'io.github.molakesizhanfangguangmang.biliharbor.test');
    });

    test('正文或设备号为空直接判失败，不发请求', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return _json(<String, Object?>{'ok': true});
      });

      expect(
        await submitFeedback(deviceId: '', text: 'x', client: client),
        FeedbackStatus.failed,
      );
      expect(
        await submitFeedback(deviceId: 'd', text: '  ', client: client),
        FeedbackStatus.failed,
      );
      expect(called, isFalse);
    });

    test('票据被拒按 nonceInvalid 收敛，可重试', () async {
      final client = MockClient(
        (request) async => _json(
          <String, Object?>{'ok': false, 'error': 'nonce_invalid'},
          403,
        ),
      );

      expect(
        await submitFeedback(deviceId: 'd', text: 'x', client: client),
        FeedbackStatus.nonceInvalid,
      );
    });
  });
}
