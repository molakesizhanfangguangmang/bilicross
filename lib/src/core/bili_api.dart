import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models.dart';
import 'log_store.dart';
import 'signing.dart';

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
        'User-Agent': userAgent ?? settings.userAgent,
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
          'User-Agent': userAgent ?? settings.userAgent,
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
        ..headers['User-Agent'] = settings.userAgent;
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
