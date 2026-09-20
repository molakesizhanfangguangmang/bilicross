import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'http1.dart';
import 'models.dart';
import 'log_store.dart';
import 'playview.dart';
import 'signing.dart';

/// B 站风控拦截返回的错误码。
///
/// 出现它表示请求**被拦**，不代表数据为空：调用方必须当失败处理，
/// 不能 catch 之后回落成空列表，否则会把「被拦」误读成「这个 UP 确实没有合集」。
const int kRiskControlCode = -352;

class BiliException implements Exception {
  BiliException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

class AppAuthCode {
  const AppAuthCode({required this.code, required this.url});

  final String code;
  final String url;
}

enum AppPollStatus { pending, expired, success, failed }

class AppPollOutcome {
  const AppPollOutcome({required this.status, this.token, this.message = ''});

  final AppPollStatus status;
  final AppToken? token;
  final String message;
}

/// 主接口层。只负责拼请求、判 code、还原 JSON；解析编排在 engine.dart。
class BiliApi {
  BiliApi({required this.settings, http.Client? client})
      : client = client ?? buildClient(settings);

  final AppSettings settings;
  final http.Client client;

  String _imgKey = '';
  String _subKey = '';

  /// 代理只在设置里配置时启用，其余走系统直连。
  static http.Client buildClient(AppSettings settings) {
    final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    final proxy = settings.proxy.trim();
    if (proxy.isNotEmpty) {
      httpClient.findProxy = (uri) => 'PROXY $proxy';
    }
    return IOClient(httpClient);
  }

  void close() => client.close();

  Future<Map<String, dynamic>> getJson(
    Uri uri, {
    String cookie = '',
    String? userAgent,
  }) async {
    LogStore.instance.add(
      '接口',
      'GET $uri${cookie.isEmpty ? '' : '（带 Cookie）'}',
      detail: true,
    );
    final http.Response response;
    try {
      response = await client.get(uri, headers: {
        'User-Agent': apiUserAgent(userAgent ?? settings.userAgent),
        'Referer': 'https://www.bilibili.com/',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      });
    } on Exception catch (error) {
      LogStore.instance.add('接口', 'GET ${uri.path} 网络失败：$error');
      rethrow;
    }
    return _decode(response, 'GET ${uri.path}');
  }

  Future<Map<String, dynamic>> postForm(
    Uri uri,
    String body, {
    String? userAgent,
  }) async {
    LogStore.instance.add('接口', 'POST $uri body=$body', detail: true);
    final http.Response response;
    try {
      response = await client.post(
        uri,
        headers: {
          'User-Agent': apiUserAgent(userAgent ?? settings.userAgent),
          'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
          'Referer': 'https://www.bilibili.com/',
        },
        body: body,
      );
    } on Exception catch (error) {
      LogStore.instance.add('接口', 'POST ${uri.path} 网络失败：$error');
      rethrow;
    }
    return _decode(response, 'POST ${uri.path}');
  }

  Map<String, dynamic> _decode(http.Response response, String label) {
    if (response.statusCode != 200) {
      LogStore.instance.add('接口', '$label 失败：接口返回 HTTP ${response.statusCode}');
      throw BiliException('接口返回 HTTP ${response.statusCode}');
    }
    final text = utf8.decode(response.bodyBytes);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      LogStore.instance.add('接口', '$label 失败：返回的不是 JSON');
      throw BiliException('接口返回的不是 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      LogStore.instance.add('接口', '$label 失败：返回结构不是对象');
      throw BiliException('接口返回结构不是对象');
    }
    LogStore.instance.add('接口', '$label -> code=${decoded['code']}', detail: true);
    return decoded;
  }

  void _check(Map<String, dynamic> json, {String action = '接口'}) {
    final code = (json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      final message = json['message'] as String? ?? '未知错误';
      LogStore.instance.add('接口', '$action 失败：$message（code=$code）');
      // 一律抛异常，包括 [kRiskControlCode]：风控被拦必须让调用方看见，
      // 不能悄悄回落成空结果。
      throw BiliException('$action失败：$message（code=$code）', code: code);
    }
  }

  void _absorbWbiKeys(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map) return;
    final wbi = data['wbi_img'];
    if (wbi is! Map) return;
    final img = wbi['img_url'] as String? ?? '';
    final sub = wbi['sub_url'] as String? ?? '';
    if (img.isNotEmpty && sub.isNotEmpty) {
      _imgKey = wbiKeyFromUrl(img);
      _subKey = wbiKeyFromUrl(sub);
    }
  }

  /// 任何使用 WBI 的接口都先保证拿到当日 key；未登录的 nav 也会下发。
  Future<String> ensureMixinKey() async {
    if (_imgKey.isNotEmpty && _subKey.isNotEmpty) {
      return mixinKeyFrom(_imgKey, _subKey);
    }
    final json = await getJson(Uri.parse('https://api.bilibili.com/x/web-interface/nav'));
    _absorbWbiKeys(json);
    if (_imgKey.isEmpty || _subKey.isEmpty) {
      throw BiliException('未取到 WBI 签名密钥');
    }
    return mixinKeyFrom(_imgKey, _subKey);
  }

  Future<AccountState> fetchAccount(String cookie) async {
    final json = await getJson(
      Uri.parse('https://api.bilibili.com/x/web-interface/nav'),
      cookie: cookie,
    );
    _absorbWbiKeys(json);
    final data = json['data'];
    if ((json['code'] as num?)?.toInt() != 0 || data is! Map || data['isLogin'] != true) {
      return AccountState(
        loggedIn: false,
        message: json['message'] as String? ?? '账号未登录',
      );
    }
    return AccountState(
      loggedIn: true,
      uname: data['uname'] as String? ?? '',
      mid: (data['mid'] as num?)?.toInt() ?? 0,
      vipStatus: (data['vipStatus'] as num?)?.toInt() ?? 0,
      vipType: (data['vipType'] as num?)?.toInt() ?? 0,
      coins: (data['money'] as num?)?.toDouble() ?? 0,
      message: 'WEB Cookie 有效',
    );
  }

  /// b23.tv 短链展开；只跟随 http(s) 跳转，最多 5 跳。
  Future<String> expandShortLink(String url) async {
    var target = Uri.parse(url);
    for (var hop = 0; hop < 5; hop++) {
      final request = http.Request('GET', target)
        ..followRedirects = false
        ..headers['User-Agent'] = apiUserAgent(settings.userAgent);
      final response = await client.send(request);
      await response.stream.drain<void>();
      if (response.isRedirect) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) break;
        target = target.resolve(location);
        continue;
      }
      break;
    }
    return target.toString();
  }

  Future<VideoInfo> fetchVideo(String cookie, {String? bvid, int? aid}) async {
    final json = await getJson(
      Uri.https('api.bilibili.com', '/x/web-interface/view', {
        if (bvid != null && bvid.isNotEmpty) 'bvid': bvid,
        if (aid != null && aid > 0) 'aid': '$aid',
      }),
      cookie: cookie,
    );
    _check(json, action: '取视频信息');
    final data = json['data'] as Map<String, dynamic>;
    final pages = (data['pages'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => PlayPage.fromJson(item.cast<String, dynamic>()))
        .toList();
    return VideoInfo(
      bvid: data['bvid'] as String? ?? '',
      aid: (data['aid'] as num?)?.toInt() ?? 0,
      title: data['title'] as String? ?? '',
      owner: (data['owner'] as Map?)?['name'] as String? ?? '',
      cover: data['pic'] as String? ?? '',
      durationSec: (data['duration'] as num?)?.toInt() ?? 0,
      pages: pages,
      // 合集清单与 pages 同在 view 的响应里，顺手解析，不额外发请求。
      season: parseUgcSeason(data['ugc_season']),
    );
  }

  /// 列出一个 UP 名下的全部合集与系列（空间弹窗用）。
  ///
  /// 合集走 `seasons_archives_list` 不行（它要 season_id），这里用
  /// `x/polymer/web-space/home/seasons_series_list?mid=&page_num=&page_size=`
  /// 一次拿全部条目；`meta[]` 是合集、`items[]` 里 type==2 的是系列。
  /// 返回两组标题+id，供弹窗挑选；条目为空不报错（这个 UP 确实没有）。
  Future<SeasonInfoList> fetchSeasonInfoList({
    required int mid,
    required String cookie,
  }) async {
    final json = await getJson(
      Uri.https('api.bilibili.com', '/x/polymer/web-space/home/seasons_series_list', {
        'mid': '$mid',
        'page_num': '1',
        'page_size': '100',
      }),
      cookie: cookie,
    );
    _check(json, action: '取合集与系列列表');
    final data = json['data'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final seasons = <SeasonInfoEntry>[];
    for (final raw in (data['meta'] as List? ?? const []).whereType<Map>()) {
      final item = raw.cast<String, dynamic>();
      final id = (item['season_id'] as num?)?.toInt() ?? 0;
      if (id <= 0) continue;
      seasons.add(SeasonInfoEntry(
        id: id,
        title: item['name'] as String? ?? '',
        total: (item['total'] as num?)?.toInt() ?? 0,
        kind: SeasonInfoKind.season,
      ));
    }
    final series = <SeasonInfoEntry>[];
    for (final raw in (data['items'] as List? ?? const []).whereType<Map>()) {
      final item = raw.cast<String, dynamic>();
      if ((item['type'] as num?)?.toInt() != 2) continue;
      final id = (item['season_id'] as num?)?.toInt() ?? 0;
      if (id <= 0) continue;
      series.add(SeasonInfoEntry(
        id: id,
        title: item['name'] as String? ?? '',
        total: (item['total'] as num?)?.toInt() ?? 0,
        kind: SeasonInfoKind.series,
      ));
    }
    return SeasonInfoList(mid: mid, seasons: seasons, series: series);
  }

  /// 按合集编号找到任一成员的 mid（翻页接口必须带 mid）。
  ///
  /// 没有专门的「season → mid」端点，这里取seasons_archives_list 不带 mid 的
  /// 变体不可行，实际做法是先试 space 搜索接口；若都失败则抛错让用户
  /// 从成员视频的 view 入口进（那条路 0 额外请求且带完整分段）。
  Future<int> findSeasonOwner(int seasonId, String cookie) async {
    // web 接口里 seasons_archives_list 必须带 mid；没有公开的 season→mid 查询，
    // 用 html 端点 cheatsheet：space.bilibili.com 之外唯一稳定来源是成员视频。
    // 因此这里调用 /x/polymer/web-space/home/seasons_series_list?mid=0 是拿不到的。
    // 直接抛错，让上层引导用户走成员视频入口。
    throw BiliException('该入口暂缺合集归属信息，请从合集内任一视频的链接进入');
  }

  /// UGC 合集：`seasons_archives_list?mid=&season_id=`，30 条/页，翻页取全。
  ///
  /// 段信息不用这个接口另取 —— `view` 的 `ugc_season` 里就有；这里服务的是
  /// 空间 lists 链接 / 裸 season_id 这类「只有 season_id、没有视频上下文」的入口，
  /// 需要先从清单里拿一个 mid 才能翻页。
  Future<VideoInfo> fetchUgcSeasonArchives({
    required int seasonId,
    required int mid,
    required String cookie,
  }) =>
      _fetchArchives(
        path: '/x/polymer/web-space/seasons_archives_list',
        idParam: 'season_id',
        id: seasonId,
        mid: mid,
        cookie: cookie,
        action: '取合集清单',
      );

  /// 系列清单：`x/series/archives`。
  ///
  /// 与合集清单同一个形状（`data.archives[]`），只是路径、参数名不同
  /// （`series_id`），且 total 藏在 `data.page.total` 里 —— 两者都认。
  Future<VideoInfo> fetchSeriesArchives({
    required int seriesId,
    required int mid,
    required String cookie,
  }) =>
      _fetchArchives(
        path: '/x/series/archives',
        idParam: 'series_id',
        id: seriesId,
        mid: mid,
        cookie: cookie,
        action: '取系列清单',
      );

  /// 合集与系列共用的翻页拉取：30 条/页，一直取到 total 为止。
  ///
  /// 段信息不用这些接口另取 —— `view` 的 `ugc_season` 里就有；这里服务的是
  /// 「只有编号、没有视频上下文」的入口（空间链接 / 空间弹窗选中的条目）。
  Future<VideoInfo> _fetchArchives({
    required String path,
    required String idParam,
    required int id,
    required int mid,
    required String cookie,
    required String action,
  }) async {
    final episodes = <SeasonEpisode>[];
    var pageNumber = 1;
    while (true) {
      final json = await getJson(
        Uri.https('api.bilibili.com', path, {
          'mid': '$mid',
          idParam: '$id',
          'page_num': '$pageNumber',
          'page_size': '30',
        }),
        cookie: cookie,
      );
      _check(json, action: action);
      final data = json['data'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final archives = (data['archives'] as List? ?? const []).whereType<Map>();
      for (final raw in archives) {
        final item = raw.cast<String, dynamic>();
        episodes.add(SeasonEpisode(
          bvid: item['bvid'] as String? ?? '',
          aid: (item['aid'] as num?)?.toInt() ?? 0,
          cid: (item['cid'] as num?)?.toInt() ?? 0,
          title: item['title'] as String? ?? '',
          durationSec: (item['duration'] as num?)?.toInt() ?? 0,
          page: episodes.length + 1,
          cover: item['pic'] as String? ?? '',
        ));
      }
      // 合集把 total 放在顶层，系列放在 page.total 里，两种都认。
      final page = data['page'] as Map<String, dynamic>?;
      final total = (data['total'] as num?)?.toInt() ??
          (page?['total'] as num?)?.toInt() ??
          episodes.length;
      if (episodes.length >= total || archives.isEmpty) break;
      pageNumber += 1;
    }

    final manifest = SeasonManifest(
      seasonId: id,
      title: '',
      owner: '',
      cover: '',
      // 翻页接口不带段信息，全部收进一个无标题段；有分段结构的合集应从
      // 某个成员视频的 view 入口进，那里能拿到完整分段。
      sections: <SeasonSection>[
        SeasonSection(id: 0, title: '', episodes: episodes),
      ],
    );
    return VideoInfo(
      bvid: '',
      aid: 0,
      title: '',
      owner: '',
      cover: '',
      durationSec: 0,
      pages: const [],
      season: manifest,
    );
  }

  /// 番剧/课程：按 ep 或 ss 取分集列表，每集带自己的 aid/cid/ep_id。
  Future<VideoInfo> fetchSeason(String cookie, {int? epId, int? seasonId}) async {
    final json = await getJson(
      Uri.https('api.bilibili.com', '/pgc/view/web/season', {
        if (epId != null && epId > 0) 'ep_id': '$epId',
        if (seasonId != null && seasonId > 0) 'season_id': '$seasonId',
      }),
      cookie: cookie,
    );
    _check(json, action: '取番剧信息');
    final data = json['data'] as Map<String, dynamic>;
    final episodes = (data['episodes'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    var page = 0;
    final pages = <PlayPage>[];
    for (final item in episodes) {
      page++;
      final title = item['title'] as String? ?? '';
      final long = item['long_title'] as String? ?? '';
      final part = long.isEmpty ? title : '$title $long';
      pages.add(PlayPage(
        page: page,
        cid: (item['cid'] as num?)?.toInt() ?? 0,
        part: part.trim(),
        durationSec: ((item['duration'] as num?)?.toInt() ?? 0) ~/ 1000,
        aid: (item['aid'] as num?)?.toInt() ?? 0,
        epId: (item['id'] as num?)?.toInt() ?? 0,
      ));
    }
    if (pages.isEmpty) {
      throw BiliException('该番剧没有可取的分集');
    }
    return VideoInfo(
      bvid: data['bvid'] as String? ?? '',
      aid: pages.first.aid,
      title: data['title'] as String? ?? '',
      owner: (data['up_info'] as Map?)?['uname'] as String? ?? '',
      cover: data['cover'] as String? ?? '',
      durationSec: pages.fold(0, (sum, item) => sum + item.durationSec),
      pages: pages,
    );
  }

  /// 网页通道 playurl，无 Cookie 也能拿到 dash，只是清晰度受限。
  Future<Map<String, dynamic>> fetchPlayUrlWeb({
    required String cookie,
    required bool bangumi,
    required int aid,
    required int cid,
    required int epId,
    required int qn,
  }) async {
    final fnval = bangumi ? kFnvalDashPgc : kFnvalDash;
    final params = <String, String>{
      'support_multi_audio': 'true',
      'from_client': 'BROWSER',
      'avid': '$aid',
      'cid': '$cid',
      'fnval': '$fnval',
      'fnver': '0',
      'fourk': '1',
      'otype': 'json',
      'qn': '$qn',
    };
    if (bangumi) {
      params['module'] = 'bangumi';
      params['ep_id'] = '$epId';
      params['session'] = '';
    }
    if (cookie.isEmpty) {
      params['try_look'] = '1';
      params['gaia_source'] = 'pre-load';
    }
    params['wts'] = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';

    final String query;
    if (bangumi) {
      query = buildQuery(params);
    } else {
      final mixinKey = await ensureMixinKey();
      params['w_rid'] = wbiSign(params: params, mixinKey: mixinKey);
      query = buildQuery(params);
    }
    final path = bangumi ? '/pgc/player/web/v2/playurl' : '/x/player/wbi/playurl';
    LogStore.instance.add(
      '解析',
      '网页通道请求：qn=$qn fnval=$fnval${bangumi ? '（番剧端点）' : ''}'
      ' Cookie=${cookie.isEmpty ? '无' : '有'}',
    );
    final json = await getJson(
      Uri.parse('https://api.bilibili.com$path?$query'),
      cookie: cookie,
    );
    _check(json, action: '网页通道解析');
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw BiliException('网页通道解析返回空数据');
    }
    return data;
  }

  /// APP 通道 playurl：appkey + 签名，access_key 可选。
  ///
  /// 先带 HDR Vivid 位（16384）请求，该位只有 APP 端点认；万一被拒，去掉这一位再试一次，
  /// 别因为多要一个档位把整条 APP 通道弄丢。
  Future<Map<String, dynamic>> fetchPlayUrlApp({
    required String accessToken,
    required int aid,
    required int cid,
    required int qn,
  }) async {
    try {
      return await _requestAppPlayurl(
        accessToken: accessToken,
        aid: aid,
        cid: cid,
        qn: qn,
        fnval: kFnvalDashApp,
      );
    } on BiliException catch (error) {
      LogStore.instance.add(
        '解析',
        'APP 通道带 HDR Vivid 位（$kFnvalDashApp）失败：${error.message}，'
        '改用 fnval=$kFnvalDash 再试',
      );
    }
    return _requestAppPlayurl(
      accessToken: accessToken,
      aid: aid,
      cid: cid,
      qn: qn,
      fnval: kFnvalDash,
    );
  }

  Future<Map<String, dynamic>> _requestAppPlayurl({
    required String accessToken,
    required int aid,
    required int cid,
    required int qn,
    required int fnval,
  }) async {
    final params = <String, String>{
      'appkey': settings.appKey,
      'avid': '$aid',
      'cid': '$cid',
      'fnval': '$fnval',
      'fnver': '0',
      'fourk': '1',
      'mobi_app': 'android',
      'platform': 'android',
      'qn': '$qn',
      'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      if (accessToken.isNotEmpty) 'access_key': accessToken,
    };
    final entries = params.entries
        .map((entry) => '${entry.key}=${encodeComponent(entry.value)}')
        .join('&');
    final sign = appSign(query: entries, appSecret: settings.appSec);
    LogStore.instance.add(
      '解析',
      'APP 通道请求：qn=$qn fnval=$fnval'
      ' access_key=${accessToken.isEmpty ? '无' : '有'}',
    );
    final json = await getJson(
      Uri.parse('https://api.bilibili.com/x/player/playurl?$entries&sign=$sign'),
      userAgent: kAppUserAgent,
    );
    _check(json, action: 'APP 通道解析');
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw BiliException('APP 通道解析返回空数据');
    }
    return data;
  }

  /// gRPC PlayView：REST 端点不给的档位（129 HDR Vivid）只能从这里取。
  ///
  /// 服务端在 HTTP/1.1 上也接受 `application/grpc+proto` 的 5 字节帧，所以不必
  /// 为它引入 http2 / gRPC 依赖。qn 固定 127：该端点的档位表不受 qn 限制，
  /// 传小值也不会省数据（实测 qn=80 时 129 依然在列）。
  Future<Map<String, dynamic>> fetchPlayUrlAppGrpc({
    required String accessToken,
    required int aid,
    required int cid,
    int qn = 127,
  }) async {
    final message = PlayViewCodec.encodeRequest(aid: aid, cid: cid, qn: qn);
    LogStore.instance.add(
      '解析',
      'gRPC PlayView 请求：aid=$aid cid=$cid qn=$qn'
      ' fnval=${PlayViewCodec.fnvalVivid} access_key=${accessToken.isEmpty ? '无' : '有'}',
    );
    // 这条请求不走 dart:io 的 HttpClient：响应是 chunked 且终止块后面还带 trailer，
    // dart:io 的解析器读到 trailer 首字节就抛
    // `Failed to parse HTTP, 98 does not match 13`（详见 http1.dart）。
    final Http1Response response;
    try {
      response = await http1Post(
        host: PlayViewCodec.host,
        path: PlayViewCodec.method,
        proxy: settings.proxy,
        headers: {
          'User-Agent': PlayViewCodec.userAgent,
          'Content-Type': 'application/grpc+proto',
          'Accept': 'application/grpc+proto',
          'TE': 'trailers',
          'x-grpc-web': '1',
          if (accessToken.isNotEmpty) 'authorization': 'identify_v1 $accessToken',
          ...PlayViewCodec.binaryHeaders(accessToken: accessToken),
        },
        body: PlayViewCodec.frame(message),
      );
    } on Exception catch (error) {
      LogStore.instance.add('接口', 'gRPC PlayView 网络失败：$error');
      throw BiliException('gRPC 请求失败：$error');
    }
    if (response.statusCode != 200) {
      LogStore.instance.add('接口', 'gRPC PlayView 失败：HTTP ${response.statusCode}');
      throw BiliException('gRPC 返回 HTTP ${response.statusCode}');
    }
    final grpcStatus = response.trailers['grpc-status'] ?? '0';
    LogStore.instance.add(
      '接口',
      'gRPC PlayView 传输完成：正文 ${response.body.length} 字节｜grpc-status=$grpcStatus'
      '${response.trailers['bili-trace-id'] == null ? '' : '｜trace=${response.trailers['bili-trace-id']}'}',
      detail: true,
    );
    if (grpcStatus != '0') {
      final grpcMessage = response.trailers['grpc-message'] ?? '';
      LogStore.instance.add('接口', 'gRPC PlayView 被拒：grpc-status=$grpcStatus $grpcMessage');
      throw BiliException('gRPC 返回 grpc-status=$grpcStatus${grpcMessage.isEmpty ? '' : '（$grpcMessage）'}');
    }
    final Map<String, dynamic> data;
    try {
      data = PlayViewCodec.decodeReply(PlayViewCodec.unframe(response.body));
    } on FormatException catch (error) {
      LogStore.instance.add('接口', 'gRPC PlayView 响应无法解析：$error');
      throw BiliException('gRPC 响应解析失败：$error');
    }
    final dash = data['dash'];
    final downloadable = dash is Map && dash['video'] is List
        ? (dash['video']! as List).length
        : 0;
    final qualities = data['accept_quality'];
    final vivid = qualities is List && qualities.contains(129);
    LogStore.instance.add(
      '解析',
      'gRPC PlayView 成功：可下载档位 $downloadable 条'
      '｜129 HDR Vivid ${vivid ? '有' : '无'}'
      '｜档位表 ${PlayViewCodec.describe(data)}',
      detail: true,
    );
    return data;
  }

  Future<AppAuthCode> requestAppAuthCode() async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final query = 'appkey=${settings.appKey}&local_id=0&ts=$ts';
    final sign = appSign(query: query, appSecret: settings.appSec);
    final json = await postForm(
      Uri.parse('https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code'),
      '$query&sign=$sign',
    );
    _check(json, action: '申请授权码');
    final data = json['data'];
    if (data is! Map) {
      throw BiliException('授权码返回结构异常');
    }
    final code = data['auth_code'] as String? ?? '';
    final url = data['url'] as String? ?? '';
    if (code.isEmpty || url.isEmpty) {
      throw BiliException('授权码为空');
    }
    return AppAuthCode(code: code, url: url);
  }

  /// 轮询授权结果。86039 为等待确认，86038 为已失效，其余按失败处理。
  Future<AppPollOutcome> pollAppAuthCode(String authCode) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final query =
        'appkey=${settings.appKey}&auth_code=${encodeComponent(authCode)}&local_id=0&ts=$ts';
    final sign = appSign(query: query, appSecret: settings.appSec);
    final json = await postForm(
      Uri.parse('https://passport.bilibili.com/x/passport-tv-login/qrcode/poll'),
      '$query&sign=$sign',
    );
    final code = (json['code'] as num?)?.toInt() ?? -1;
    switch (code) {
      case 0:
        final data = json['data'];
        if (data is! Map) {
          return const AppPollOutcome(status: AppPollStatus.failed, message: '授权返回结构异常');
        }
        final token = data['access_token'] as String? ?? '';
        if (token.isEmpty) {
          return const AppPollOutcome(status: AppPollStatus.failed, message: '授权返回空 Token');
        }
        return AppPollOutcome(
          status: AppPollStatus.success,
          token: AppToken(
            accessToken: token,
            refreshToken: data['refresh_token'] as String? ?? '',
            expiresIn: (data['expires_in'] as num?)?.toInt() ?? 0,
            mid: (data['mid'] as num?)?.toInt() ?? 0,
            obtainedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case 86039:
        return const AppPollOutcome(status: AppPollStatus.pending);
      case 86038:
        return const AppPollOutcome(status: AppPollStatus.expired, message: '授权码已失效');
      default:
        return AppPollOutcome(
          status: AppPollStatus.failed,
          message: json['message'] as String? ?? '授权失败（code=$code）',
        );
    }
  }
}

/// 解析 `view` 响应里的 `ugc_season`，得到整部合集清单。
///
/// 结构是 `ugc_season.sections[].episodes[]`，每集带 bvid / aid / cid / title，
/// 时长与封面在 `arc.duration` / `arc.pic` 里。**段信息不用另取** —— view 里就有。
///
/// 返回 null 表示这条视频不在任何合集里（正常情况，不是错误）。
SeasonManifest? parseUgcSeason(Object? raw) {
  if (raw is! Map) return null;
  final data = raw.cast<String, dynamic>();
  final seasonId = (data['id'] as num?)?.toInt() ?? 0;
  if (seasonId <= 0) return null;

  final sections = <SeasonSection>[];
  // 序号按合集内顺序从 1 起，而不是段内序号 ——
  // 这样单独下第 2 段时编号仍是 25~70，以后补下别的段不会重号。
  var order = 0;

  for (final rawSection
      in (data['sections'] as List? ?? const []).whereType<Map>()) {
    final section = rawSection.cast<String, dynamic>();
    final sectionId = (section['id'] as num?)?.toInt() ?? 0;
    final episodes = <SeasonEpisode>[];
    for (final rawEpisode
        in (section['episodes'] as List? ?? const []).whereType<Map>()) {
      final episode = rawEpisode.cast<String, dynamic>();
      final arc = (episode['arc'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      order += 1;
      episodes.add(SeasonEpisode(
        bvid: episode['bvid'] as String? ?? '',
        aid: (episode['aid'] as num?)?.toInt() ?? 0,
        cid: (episode['cid'] as num?)?.toInt() ?? 0,
        title: episode['title'] as String? ?? '',
        durationSec: (arc['duration'] as num?)?.toInt() ?? 0,
        page: order,
        cover: arc['pic'] as String? ?? '',
        sectionId: sectionId,
      ));
    }
    if (episodes.isEmpty) continue;
    sections.add(SeasonSection(
      id: sectionId,
      title: section['title'] as String? ?? '',
      episodes: episodes,
    ));
  }

  if (sections.isEmpty) return null;
  return SeasonManifest(
    seasonId: seasonId,
    title: data['title'] as String? ?? '',
    owner: ((data['upper'] as Map?)?['name'] as String?) ?? '',
    cover: data['cover'] as String? ?? '',
    sections: sections,
  );
}
