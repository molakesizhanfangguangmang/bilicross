import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/bili_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('凭据失效提示', () {
    // 只有明确的未登录信号才提示重新登录：本来是游客、或撞的是别的问题，
    // 说「Cookie 已失效」等于把人往没用的方向引。
    test('REST -101 且有 Cookie：判 Cookie 失效', () {
      expect(
        AppState.authNoticeFor(
          BiliException('网页通道解析失败：账号未登录（code=-101）', code: -101),
          hasCookie: true,
          hasToken: false,
        ),
        'Cookie 已失效，请重新登录',
      );
    });

    test('REST -101 且只有 Token：判 APP Token 失效', () {
      expect(
        AppState.authNoticeFor(
          BiliException('网页通道解析失败：账号未登录（code=-101）', code: -101),
          hasCookie: false,
          hasToken: true,
        ),
        'APP Token 已失效，请重新登录',
      );
    });

    test('gRPC UNAUTHENTICATED 判 APP Token 失效', () {
      expect(
        AppState.authNoticeFor(
          BiliException('gRPC 返回 grpc-status=16（UNAUTHENTICATED）'),
          hasCookie: true,
          hasToken: true,
        ),
        'APP Token 已失效，请重新登录',
      );
    });

    test('没有凭据的未登录不算失效', () {
      expect(
        AppState.authNoticeFor(
          BiliException('网页通道解析失败：账号未登录（code=-101）', code: -101),
          hasCookie: false,
          hasToken: false,
        ),
        isNull,
      );
    });

    test('风控与参数错误不提示重新登录', () {
      for (final code in <int>[-352, -400, -403, -404]) {
        expect(
          AppState.authNoticeFor(
            BiliException('解析失败（code=$code）', code: code),
            hasCookie: true,
            hasToken: true,
          ),
          isNull,
          reason: 'code=$code 不该被当成凭据失效',
        );
      }
    });

    test('网络异常不提示重新登录', () {
      expect(
        AppState.authNoticeFor(
          const SocketExceptionLike('Connection refused'),
          hasCookie: true,
          hasToken: true,
        ),
        isNull,
      );
    });
  });
}

/// 只是拿个非 BiliException 的异常对象来试：真实的网络异常也会走这一条路。
class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);

  final String message;

  @override
  String toString() => 'SocketException: $message';
}
