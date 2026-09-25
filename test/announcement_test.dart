import 'dart:convert';
import 'dart:io';

import 'package:bilicross/src/core/announcement.dart';
import 'package:bilicross/src/core/announcement_center.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _poll({
  String id = 'p1',
  bool multi = false,
  bool open = true,
}) =>
    <String, Object?>{
      'id': id,
      'question': '选一个',
      'multi': multi,
      'open': open,
      'options': <Object>[
        <String, Object?>{'id': 'o1', 'label': '甲'},
        <String, Object?>{'id': 'o2', 'label': '乙'},
      ],
    };

/// 中文正文必须显式声明 utf-8：`http.Response(String, int)` 默认按 latin1 编码 bodyBytes，
/// 而 `fetchAnnouncements` 是按 utf8 解 bodyBytes 的。
http.Response _json(Object? payload, [int status = 200]) => http.Response(
      jsonEncode(payload),
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

http.Response _feed(List<Map<String, Object?>> items) =>
    _json(<String, Object?>{'announcements': items});

void main() {
  group('解析', () {
    test('字段读全；缺字段的按「可关闭」兜底，没有 id 的直接丢', () {
      final list = parseAnnouncements(jsonEncode(<String, Object?>{
        'announcements': <Object>[
          <String, Object?>{
            'id': 'a1',
            'title': '标题',
            'body': '正文',
            'closable': false,
            'dismissMode': kDismissSession,
            'action': <String, Object?>{'label': '去投票'},
            'platforms': <Object?>['android', '', null],
            'minVersion': '2.0.0',
            'maxVersion': '2.1.0',
            'startsAt': 100,
            'expiresAt': '1970-01-01T00:16:40Z',
            'poll': _poll(multi: true),
          },
          <String, Object?>{'id': 'a2'},
          <String, Object?>{'title': '没有 id'},
          '不是对象',
        ],
      }));

      expect(list, hasLength(2));
      final first = list.first;
      expect(first.forced, isTrue);
      expect(first.sessionOnly, isTrue);
      expect(first.actionLabel, '去投票');
      // 空串与非字符串都被滤掉，只留平台名。
      expect(first.platforms, <String>['android']);
      expect(first.startsAt, 100);
      expect(first.expiresAt, 1000);
      expect(first.poll?.multi, isTrue);
      expect(first.poll?.options.map((o) => o.id), <String>['o1', 'o2']);

      final second = list.last;
      expect(second.closable, isTrue, reason: '少写 closable 不能把用户锁死在弹窗里');
      expect(second.forced, isFalse);
      expect(second.dismissMode, kDismissForever);
      expect(second.poll, isNull);
      expect(second.startsAt, isNull);
    });

    test('坏输入一律当空列表，不往外抛', () {
      expect(parseAnnouncements('{'), isEmpty);
      expect(parseAnnouncements('[]'), isEmpty);
      expect(parseAnnouncements('{}'), isEmpty);
      expect(parseAnnouncements(jsonEncode(<String, Object?>{'announcements': 'x'})),
          isEmpty);
      expect(parseAnnouncements(''), isEmpty);
    });

    test('poll 缺 id 或缺可选项 → 当作没有投票（渲染不出来的东西不进界面）', () {
      expect(AnnouncementPoll.fromJson(<String, Object?>{'options': <Object>[]}), isNull);
      expect(
        AnnouncementPoll.fromJson(<String, Object?>{'id': 'p', 'options': <Object>[]}),
        isNull,
      );
      expect(AnnouncementPoll.fromJson('不是对象'), isNull);
      // open 字段缺失按「开着」处理（老数据）。
      expect(
        AnnouncementPoll.fromJson(<String, Object?>{
          'id': 'p',
          'options': <Object>[
            <String, Object?>{'id': 'o1'},
          ],
        })?.open,
        isTrue,
      );
    });
  });

  group('版本门控', () {
    test('版本键只取前三段：内测的第四段不参与比较', () {
      expect(versionKey('2.1.6.4'), versionKey('2.1.6'));
      expect(versionKey('v2.1.6'), <int>[2, 1, 6]);
      expect(versionKey('2.1'), <int>[2, 1, 0]);
      expect(versionKey(''), <int>[0, 0, 0]);
      expect(compareVersionKey(versionKey('2.1.6'), versionKey('2.2.0')), isNegative);
      expect(compareVersionKey(versionKey('2.2.0'), versionKey('2.2.0')), 0);
      expect(compareVersionKey(versionKey('3.0'), versionKey('2.9.9')), isPositive);
    });

    test('maxVersion 之上的版本看不到 —— 更新性公告只发老版本', () {
      final forced = Announcement.fromJson(<String, Object?>{
        'id': 'f',
        'closable': false,
        'maxVersion': '2.1.0',
      })!;
      final now = DateTime.utc(2026, 9, 25);
      bool sees(String version) =>
          forced.visibleFor(version: version, platform: 'android', now: now);

      expect(sees('2.0.9'), isTrue);
      expect(sees('2.1.0'), isTrue, reason: '边界含等号');
      expect(sees('2.1.0.7'), isTrue, reason: '内测第四段不影响判定');
      expect(sees('2.1.6'), isFalse, reason: '新版不该看到这条强制更新');
      expect(sees('2.2.0'), isFalse);
    });

    test('平台与时间窗；平台未知（空串）时不按平台过滤', () {
      final item = Announcement.fromJson(<String, Object?>{
        'id': 'a',
        'platforms': <Object>['android'],
        'startsAt': 1000,
        'expiresAt': 2000,
      })!;
      DateTime at(int seconds) =>
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      bool sees(String platform, int seconds) =>
          item.visibleFor(version: '2.0.0', platform: platform, now: at(seconds));

      expect(sees('windows', 1500), isFalse);
      expect(sees('android', 999), isFalse, reason: '还没开始');
      expect(sees('android', 1500), isTrue);
      expect(sees('android', 2001), isFalse, reason: '已过期');
      expect(sees('', 1500), isTrue);
    });
  });

  group('公告中心', () {
    late Directory dir;
    late Store store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bilicross-announcement');
      store = Store.at(dir);
    });

    tearDown(() async {
      // Windows 上句柄释放有延迟（errno 145），删目录必须重试。
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          await dir.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    AnnouncementCenter buildCenter(MockClient client) => AnnouncementCenter(
          store: store,
          client: client,
          baseUrl: 'https://announce.test',
          version: '2.0.0',
          platform: 'android',
        );

    /// `start()` 里那次拉取是「发了不管」的，要拿到内容得自己再等一次。
    Future<AnnouncementCenter> startedWith(AnnouncementCenter center) async {
      await center.start();
      await center.refresh(manual: true);
      return center;
    }

    test('弹窗队列：不可关闭的排前面；已投 / 已结束的不进队', () async {
      final center = buildCenter(MockClient((_) async => _feed(<Map<String, Object?>>[
            <String, Object?>{'id': 'normal', 'title': '普通'},
            <String, Object?>{'id': 'forced', 'title': '强制', 'closable': false},
            <String, Object?>{'id': 'polled', 'title': '投票', 'poll': _poll()},
            <String, Object?>{
              'id': 'closedPoll',
              'title': '已结束',
              'poll': _poll(id: 'p2', open: false),
            },
          ])));
      await startedWith(center);

      // 已结束的那条被 visibleFor 之类的前置过滤挡在弹窗之外，但列表里还在。
      expect(center.items.map((i) => i.id),
          <String>['normal', 'forced', 'polled', 'closedPoll']);

      expect(center.takeNextPopup()?.id, 'forced');
      expect(center.takeNextPopup()?.id, 'normal');
      expect(center.takeNextPopup()?.id, 'polled');
      expect(center.takeNextPopup(), isNull);
      center.dispose();
    });

    test('关闭三态：forever 落盘、session 重启就忘、forced 不给关', () async {
      final client = MockClient((_) async => _feed(<Map<String, Object?>>[
            <String, Object?>{'id': 'forever', 'title': 'A'},
            <String, Object?>{'id': 'session', 'title': 'B', 'dismissMode': kDismissSession},
            <String, Object?>{'id': 'forced', 'title': 'C', 'closable': false},
          ]));
      final center = await startedWith(buildCenter(client));
      final byId = <String, Announcement>{
        for (final item in center.items) item.id: item,
      };

      // 不可关闭的：不给关，队列里的那份也不能被悄悄摘掉。
      await center.dismiss(byId['forced']!);
      expect(center.isDismissed('forced'), isFalse);
      await center.dismiss(byId['forced']!, force: true);
      expect(center.isDismissed('forced'), isTrue);

      await center.dismiss(byId['forever']!);
      await center.dismiss(byId['session']!);
      expect(center.isDismissed('forever'), isTrue);
      expect(center.isDismissed('session'), isTrue);
      expect(center.unreadCount, 0);
      center.dispose();

      // 「重启」：同一份数据目录再建一个。
      final reopened = await startedWith(buildCenter(client));
      expect(reopened.isDismissed('forever'), isTrue, reason: 'forever 已读要落盘');
      expect(reopened.isDismissed('session'), isFalse, reason: 'session 只管本次运行');
      expect(reopened.isDismissed('forced'), isTrue);
      reopened.dispose();
    });

    test('投票：投出去就记下且不给改；投过的公告不再弹', () async {
      var posted = 0;
      String? postedBody;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          posted += 1;
          postedBody = request.body;
          return _json(<String, Object?>{'ok': true});
        }
        return _feed(<Map<String, Object?>>[
          <String, Object?>{'id': 'vote', 'title': '投票', 'poll': _poll()},
        ]);
      });
      final center = await startedWith(buildCenter(client));
      final announcement = center.items.single;
      expect(center.deviceId, isNotEmpty);

      expect(await center.vote(announcement, <String>['o1']), isTrue);
      expect(posted, 1);
      // 设备号与已提交的选项都要带出去 —— 服务端按 (poll_id, device_id) 去重。
      final body = jsonDecode(postedBody!) as Map<String, Object?>;
      expect(body['poll_id'], 'p1');
      expect(body['device_id'], center.deviceId);
      expect(body['options'], <String>['o1']);

      expect(center.hasVoted('p1'), isTrue);
      expect(center.votedOptions('p1'), <String>['o1']);
      expect(center.takeNextPopup(), isNull, reason: '投过的不再弹');

      // 不让改票：第二次直接返回 false，也不会再发一次请求。
      expect(await center.vote(announcement, <String>['o2']), isFalse);
      expect(posted, 1);
      center.dispose();
    });

    test('投票失败不记「已投」，公告还留在队列里', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST') return _json(<String, Object?>{}, 500);
        return _feed(<Map<String, Object?>>[
          <String, Object?>{'id': 'vote', 'title': '投票', 'poll': _poll()},
        ]);
      });
      final center = await startedWith(buildCenter(client));
      final announcement = center.items.single;

      expect(await center.vote(announcement, <String>['o1']), isFalse);
      expect(center.hasVoted('p1'), isFalse);
      expect(center.takeNextPopup()?.id, 'vote');
      center.dispose();
    });

    test('拉取失败：保留上一次的内容、不抛异常，且不在后台排重试', () async {
      var online = false;
      final client = MockClient((_) async => online
          ? _feed(<Map<String, Object?>>[
              <String, Object?>{'id': 'a', 'title': '有内容'},
            ])
          : _json(<String, Object?>{}, 500));
      final center = await startedWith(buildCenter(client));
      expect(center.failed, isTrue);
      expect(center.items, isEmpty);
      expect(center.lastFetchAt, isNull);

      // 进后台：退避探针必须停掉，不要在后台空转。
      center.setForeground(false);
      expect(center.failed, isTrue);

      // 回前台（＝恢复联网）：立刻补一次，内容到手。
      online = true;
      center.setForeground(true);
      await center.refresh(manual: true);
      expect(center.failed, isFalse);
      expect(center.items.map((i) => i.id), <String>['a']);
      expect(center.lastFetchAt, isNotNull);
      center.dispose();
    });

    test('设备号落盘并在重启后沿用（同一台机一票）', () async {
      final offline = MockClient((_) async => _json(<String, Object?>{}, 500));
      final first = buildCenter(offline);
      await first.start();
      final id = first.deviceId;
      expect(id, hasLength(32));
      first.dispose();

      final second = buildCenter(offline);
      await second.start();
      expect(second.deviceId, id);
      second.dispose();
    });
  });
}
