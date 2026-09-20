import 'package:bilicross/src/core/bili_api.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 空间「合集 / 系列」列表的真实返回形状（2026-09-20 用真实请求抓下来精简过的）。
///
/// 这个形状当初写错过一次：路径多了 `/home/`（404），并且把编号读成
/// `data.meta` / `data.items`。把真实形状钉在测试里，改坏了能立刻发现。
Map<String, dynamic> _fixture() => <String, dynamic>{
      'code': 0,
      'message': 'OK',
      'data': <String, dynamic>{
        'items_lists': <String, dynamic>{
          'page': <String, dynamic>{'page_num': 1, 'page_size': 20, 'total': 10},
          'seasons_list': <dynamic>[
            <String, dynamic>{
              'meta': <String, dynamic>{
                'season_id': 6645074,
                'name': '合集·倪海厦',
                'total': 2,
                'mid': 11231484,
              },
              'archives': <dynamic>[],
            },
            <String, dynamic>{
              'meta': <String, dynamic>{
                'season_id': 3144260,
                'name': '合集·人体的十四经络穴位讲解',
                'total': 229,
              },
            },
          ],
          'series_list': <dynamic>[
            <String, dynamic>{
              'meta': <String, dynamic>{
                'series_id': 1114283,
                'name': '栗原纱英',
                'total': 5,
              },
            },
          ],
        },
      },
    };

void main() {
  group('空间合集/系列列表解析', () {
    test('合集与系列分别取到编号、名称、集数', () {
      final list = BiliApi.parseSeasonInfoList(_fixture(), 11231484);

      expect(list.mid, 11231484);
      expect(list.seasons.length, 2);
      expect(list.seasons.first.id, 6645074);
      expect(list.seasons.first.title, '合集·倪海厦');
      expect(list.seasons.first.total, 2);
      expect(list.seasons.first.kind, SeasonInfoKind.season);
      // 设计定案里的样例合集，229 集。
      expect(list.seasons.last.id, 3144260);
      expect(list.seasons.last.total, 229);

      expect(list.series.length, 1);
      expect(list.series.first.id, 1114283);
      expect(list.series.first.title, '栗原纱英');
      expect(list.series.first.total, 5);
      expect(list.series.first.kind, SeasonInfoKind.series);
    });

    test('系列用 series_id，不会被当成 season_id', () {
      final list = BiliApi.parseSeasonInfoList(_fixture(), 1);
      // 系列条目里没有 season_id；如果读错字段，id 会变成 0 而被丢掉。
      expect(list.series.single.id, 1114283);
    });

    test('编号缺失的条目跳过，不产生 id 为 0 的条目', () {
      final json = <String, dynamic>{
        'data': <String, dynamic>{
          'items_lists': <String, dynamic>{
            'seasons_list': <dynamic>[
              <String, dynamic>{'meta': <String, dynamic>{'name': '没有编号'}},
              <String, dynamic>{
                'meta': <String, dynamic>{'season_id': 42, 'name': '正常', 'total': 3},
              },
            ],
          },
        },
      };
      final list = BiliApi.parseSeasonInfoList(json, 7);
      expect(list.seasons.length, 1);
      expect(list.seasons.single.id, 42);
      expect(list.series, isEmpty);
    });

    test('没有 meta 子对象时退回条目本身（接口换个写法也不至于全空）', () {
      final json = <String, dynamic>{
        'data': <String, dynamic>{
          'items_lists': <String, dynamic>{
            'seasons_list': <dynamic>[
              <String, dynamic>{'season_id': 99, 'name': '扁平写法', 'total': 4},
            ],
          },
        },
      };
      final list = BiliApi.parseSeasonInfoList(json, 7);
      expect(list.seasons.single.id, 99);
      expect(list.seasons.single.title, '扁平写法');
    });

    test('空返回与缺字段都不抛异常', () {
      expect(BiliApi.parseSeasonInfoList(<String, dynamic>{}, 1).seasons, isEmpty);
      expect(
        BiliApi.parseSeasonInfoList(
          <String, dynamic>{'data': <String, dynamic>{}},
          1,
        ).series,
        isEmpty,
      );
      expect(
        BiliApi.parseSeasonInfoList(
          <String, dynamic>{
            'data': <String, dynamic>{
              'items_lists': <String, dynamic>{'seasons_list': <dynamic>[]},
            },
          },
          1,
        ).seasons,
        isEmpty,
      );
    });
  });
}
