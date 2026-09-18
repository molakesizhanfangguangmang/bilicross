import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bili_api.dart';
import 'log_store.dart';
import 'models.dart';
import 'signing.dart';

/// 扫码流程的状态。文案由界面按当前语言翻译，core 层不持有 l10n。
enum QrLoginStage {
  /// 正在取二维码。
  loading,

  /// 等待用户扫码。
  waitingScan,

  /// 已扫码，等待用户在手机端确认。
  waitingConfirm,

  /// 登录成功，且已拿到完整的网页登录 Cookie。
  success,

  /// 二维码已失效，需要刷新。
  expired,

  /// 用户主动取消。
  canceled,

  /// 轮询超时。
  timeout,

  /// 网络错误。
  networkError,

  /// 接口不可用（外层 code 非 0、响应结构异常，或 Cookie 缺字段）。
  unavailable,
}

/// 一张二维码：内容是给用户扫的地址，key 只用于轮询。
/// 两者都不进日志。
class QrLoginChallenge {
  const QrLoginChallenge({required this.content, required this.key});

  final String content;
  final String key;
}

/// 取二维码的结果。失败时 [challenge] 为空、[stage] 说明原因。
class QrChallengeResult {
  const QrChallengeResult({
    required this.stage,
    this.challenge,
  });

  final QrLoginStage stage;
  final QrLoginChallenge? challenge;
}

/// 一次轮询的结果。
class QrPollOutcome {
  const QrPollOutcome(
    this.stage, {
    this.cookie,
    this.missingFields = const <String>[],
  });

  final QrLoginStage stage;

  /// 仅在 [QrLoginStage.success] 时非空。
  final WebCookie? cookie;

  /// Cookie 不完整时缺的字段名（如 bili_jct），界面据此给出明确错误。
  final List<String> missingFields;
}

/// 一次状态更新，界面只消费它。
class QrLoginUpdate {
  const QrLoginUpdate(
    this.stage, {
    this.content,
    this.cookie,
    this.missingFields = const <String>[],
  });

  final QrLoginStage stage;

  /// 当前二维码内容；没有码可显示时为 null。
  final String? content;

  final WebCookie? cookie;
  final List<String> missingFields;

  bool get isSuccess => stage == QrLoginStage.success;
}

/// B 站网页扫码登录接口封装。
///
/// 接口实测（2026-09-18，桌面 UA + Referer www.bilibili.com）：
///
/// - `GET /x/passport-login/web/qrcode/generate`
///   → `{"code":0,"data":{"url":"https://account.bilibili.com/h5/…","qrcode_key":"32 位"}}`
///   `url` 就是二维码内容，`qrcode_key` 有效期约 3 分钟。
/// - `GET /x/passport-login/web/qrcode/poll?qrcode_key=…`
///   → 外层 `code` 为 0 表示请求成功，真正的状态在内层 `data.code`：
///   `86101` 未扫码｜`86090` 已扫码待确认｜`86038` 二维码失效｜`0` 登录成功。
///   成功时 `data` 里会带 `url`（crossDomain 跳转地址）与 `refresh_token`。
/// - 成功时的三个网页 Cookie 可能出现在响应的 `Set-Cookie` 头，
///   也可能挂在 `data.url` 的查询参数上，所以这里两处都取，合并后交给
///   现有的 [CookieParser]，不另立一套 Cookie 模型。
///
/// 安全约定：二维码 key、完整响应体、Cookie 与 token 一律不写日志，
/// 日志里只出现状态名。
class QrLoginService {
  QrLoginService({
    AppSettings? settings,
    http.Client? client,
    this.userAgent = kDesktopUserAgent,
    this.requestTimeout = const Duration(seconds: 20),
  })  : _settings = settings,
        _client = client;

  static const String generateUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
  static const String pollUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';

  /// 内层状态码。
  static const int codeSuccess = 0;
  static const int codeWaitingScan = 86101;
  static const int codeWaitingConfirm = 86090;
  static const int codeExpired = 86038;

  /// 登录成功必须齐的三个字段。
  static const List<String> requiredFields = <String>[
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
  ];

  final AppSettings? _settings;
  final String userAgent;
  final Duration requestTimeout;
  http.Client? _client;

  /// 复用一个客户端（设置里配了代理时也走同一条出口）。
  http.Client get _http {
    final existing = _client;
    if (existing != null) return existing;
    final settings = _settings;
    final created =
        settings == null ? http.Client() : BiliApi.buildClient(settings);
    _client = created;
    return created;
  }

  /// 中止在途请求。页面离开或用户取消时调用；
  /// 下次请求会自动重建客户端，所以服务仍然可以继续用。
  void abort() {
    _client?.close();
    _client = null;
  }

  Map<String, String> get _headers => <String, String>{
        'User-Agent': userAgent,
        'Referer': 'https://www.bilibili.com/',
        'Accept': 'application/json, text/plain, */*',
      };

  /// 取一张新二维码。不做重试：失败交给界面显示状态与「刷新二维码」。
  Future<QrChallengeResult> requestQrCode() async {
    final Map<String, dynamic> body;
    try {
      final response = await _http
          .get(Uri.parse(generateUrl), headers: _headers)
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        return const QrChallengeResult(stage: QrLoginStage.unavailable);
      }
      body = _decode(response.body);
    } on Exception {
      return const QrChallengeResult(stage: QrLoginStage.networkError);
    }
    if (body.isEmpty) {
      return const QrChallengeResult(stage: QrLoginStage.unavailable);
    }
    if ((body['code'] as num?)?.toInt() != 0) {
      return const QrChallengeResult(stage: QrLoginStage.unavailable);
    }
    final data = body['data'];
    if (data is! Map) {
      return const QrChallengeResult(stage: QrLoginStage.unavailable);
    }
    final content = data['url'];
    final key = data['qrcode_key'];
    if (content is! String || key is! String || content.isEmpty || key.isEmpty) {
      return const QrChallengeResult(stage: QrLoginStage.unavailable);
    }
    return QrChallengeResult(
      stage: QrLoginStage.waitingScan,
      challenge: QrLoginChallenge(content: content, key: key),
    );
  }

  /// 轮询一次。网络与结构问题都变成状态返回，不往外抛。
  Future<QrPollOutcome> pollOnce(String key) async {
    final Map<String, dynamic> body;
    final http.Response response;
    try {
      response = await _http
          .get(
            Uri.parse(pollUrl).replace(
              queryParameters: <String, String>{'qrcode_key': key},
            ),
            headers: _headers,
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        return const QrPollOutcome(QrLoginStage.unavailable);
      }
      body = _decode(response.body);
    } on Exception {
      return const QrPollOutcome(QrLoginStage.networkError);
    }
    if (body.isEmpty) {
      return const QrPollOutcome(QrLoginStage.unavailable);
    }
    if ((body['code'] as num?)?.toInt() != 0) {
      return const QrPollOutcome(QrLoginStage.unavailable);
    }
    final data = body['data'];
    if (data is! Map) {
      return const QrPollOutcome(QrLoginStage.unavailable);
    }
    final inner = (data['code'] as num?)?.toInt();
    switch (inner) {
      case codeWaitingScan:
        return const QrPollOutcome(QrLoginStage.waitingScan);
      case codeWaitingConfirm:
        return const QrPollOutcome(QrLoginStage.waitingConfirm);
      case codeExpired:
        return const QrPollOutcome(QrLoginStage.expired);
      case codeSuccess:
        return _successOutcome(response: response, data: data);
      default:
        // 没见过的状态码：按接口不可用处理，界面会引导去网页登录。
        return const QrPollOutcome(QrLoginStage.unavailable);
    }
  }

  QrPollOutcome _successOutcome({
    required http.Response response,
    required Map<dynamic, dynamic> data,
  }) {
    final fields = <String, String>{};
    final header = response.headers['set-cookie'];
    if (header != null && header.isNotEmpty) {
      fields.addAll(cookieFieldsFromHeaders(header));
    }
    final crossDomain = data['url'];
    if (crossDomain is String && crossDomain.isNotEmpty) {
      for (final entry in queryFieldsOf(crossDomain).entries) {
        fields.putIfAbsent(entry.key, () => entry.value);
      }
    }
    if (fields.isEmpty) {
      return const QrPollOutcome(QrLoginStage.unavailable);
    }
    // 先在原始字段上判断缺谁：CookieParser 只认 SESSDATA，缺 SESSDATA 时
    // 直接返回空 Cookie，看不出到底缺哪几个。
    final missing = <String>[
      if (!_hasField(fields, 'SESSDATA')) 'SESSDATA',
      if (!_hasField(fields, 'bili_jct')) 'bili_jct',
      if (!_hasField(fields, 'DedeUserID')) 'DedeUserID',
    ];
    if (missing.isNotEmpty) {
      // 字段不全就不算成功：宁可让用户重扫或改走网页登录，
      // 也不把半套凭据写进存储。
      return QrPollOutcome(QrLoginStage.unavailable, missingFields: missing);
    }
    final cookie = CookieParser.parse(
      fields.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
    if (cookie.isEmpty || !cookie.isComplete) {
      return const QrPollOutcome(QrLoginStage.unavailable);
    }
    return QrPollOutcome(QrLoginStage.success, cookie: cookie);
  }

  static bool _hasField(Map<String, String> fields, String name) {
    final value = fields[name];
    if (value != null && value.isNotEmpty) return true;
    for (final entry in fields.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase() && entry.value.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  /// `Set-Cookie` 会有多条，http 包把它们用 `, ` 拼成一个字符串；
  /// 而属性里的 `Expires` 本身带逗号，所以只在「逗号后面紧跟 name=」处切。
  static Map<String, String> cookieFieldsFromHeaders(String header) {
    final fields = <String, String>{};
    for (final part in header.split(RegExp(r',(?=\s*[A-Za-z0-9_.\-]+=)'))) {
      final pair = part.split(';').first.trim();
      final index = pair.indexOf('=');
      if (index <= 0) continue;
      final name = pair.substring(0, index).trim();
      final value = pair.substring(index + 1).trim();
      if (value.isNotEmpty) {
        fields[name] = value;
      }
    }
    return fields;
  }

  /// crossDomain 地址上的查询参数。
  static Map<String, String> queryFieldsOf(String url) {
    final fields = <String, String>{};
    final uri = Uri.tryParse(url);
    if (uri == null) return fields;
    for (final entry in uri.queryParameters.entries) {
      if (entry.value.isNotEmpty) {
        fields.putIfAbsent(entry.key, () => entry.value);
      }
    }
    return fields;
  }
}

/// 轮询器：页面只跟它打交道。取码、轮询、超时、退避与取消都收在这里，
/// 界面只消费 [updates] 流。
class QrLoginPoller {
  QrLoginPoller({
    required this.service,
    this.interval = const Duration(seconds: 3),
    this.deadline = const Duration(minutes: 3),
    this.maxConsecutiveFailures = 3,
  });

  final QrLoginService service;

  /// 轮询间隔：3 秒一次，3 分钟窗口内约 60 次，够用且不至于触发风控。
  final Duration interval;

  /// 单张二维码的轮询总时长。
  final Duration deadline;

  /// 连续失败多少次就停下来（避免网络断了还在空转）。
  final int maxConsecutiveFailures;

  final StreamController<QrLoginUpdate> _out =
      StreamController<QrLoginUpdate>.broadcast();

  Stream<QrLoginUpdate> get updates => _out.stream;

  QrLoginChallenge? _challenge;
  Timer? _timer;
  DateTime? _expiry;
  bool _polling = false;
  bool _disposed = false;
  int _failures = 0;

  /// 每次刷新或取消都会 +1：在途请求回来时对不上就直接丢掉，
  /// 免得旧二维码的结果盖掉新状态（尤其别在取消之后又弹回「等待扫码」）。
  int _generation = 0;
  QrLoginUpdate _current = const QrLoginUpdate(QrLoginStage.loading);

  QrLoginUpdate get current => _current;

  Future<void> start() => refresh();

  /// 取一张新二维码，并开始轮询（首次进入或点「刷新二维码」）。
  Future<void> refresh() async {
    if (_disposed) return;
    _stopPolling();
    _failures = 0;
    _challenge = null;
    final generation = ++_generation;
    _emit(const QrLoginUpdate(QrLoginStage.loading));
    final result = await service.requestQrCode();
    if (_disposed || generation != _generation) return;
    final challenge = result.challenge;
    if (challenge == null) {
      LogStore.instance.add('账号', '扫码登录：未取到二维码');
      _emit(QrLoginUpdate(result.stage));
      return;
    }
    LogStore.instance.add('账号', '扫码登录：已取到二维码，开始轮询');
    _challenge = challenge;
    _expiry = DateTime.now().add(deadline);
    _emit(QrLoginUpdate(QrLoginStage.waitingScan, content: challenge.content));
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    final challenge = _challenge;
    if (_disposed || _polling || challenge == null) return;
    final expiry = _expiry;
    if (expiry != null && !DateTime.now().isBefore(expiry)) {
      _stopPolling();
      // 保留二维码内容：界面把「已过期」叠在码上，比直接抹掉更清楚。
      _emit(QrLoginUpdate(QrLoginStage.timeout, content: challenge.content));
      LogStore.instance.add('账号', '扫码登录：轮询超时');
      return;
    }
    _polling = true;
    final generation = _generation;
    try {
      final outcome = await service.pollOnce(challenge.key);
      if (_disposed || generation != _generation) return;
      if (outcome.stage == QrLoginStage.networkError) {
        _failures += 1;
        _emit(
          QrLoginUpdate(
            QrLoginStage.networkError,
            content: challenge.content,
          ),
        );
        if (_failures >= maxConsecutiveFailures) {
          _stopPolling();
          LogStore.instance.add('账号', '扫码登录：连续网络失败，停止轮询');
        }
        return;
      }
      _failures = 0;
      _emit(
        QrLoginUpdate(
          outcome.stage,
          content: challenge.content,
          cookie: outcome.cookie,
          missingFields: outcome.missingFields,
        ),
      );
      if (outcome.stage == QrLoginStage.success) {
        _stopPolling();
        LogStore.instance.add('账号', '扫码登录：已取得网页 Cookie');
      } else if (outcome.stage == QrLoginStage.expired) {
        _stopPolling();
        LogStore.instance.add('账号', '扫码登录：二维码已失效');
      } else if (outcome.stage == QrLoginStage.unavailable) {
        _stopPolling();
        LogStore.instance.add('账号', '扫码登录：接口不可用');
      }
    } finally {
      _polling = false;
    }
  }

  /// 用户主动取消：停下来并给出取消状态。
  void cancel() {
    if (_disposed) return;
    _generation += 1;
    _stopPolling();
    service.abort();
    _emit(const QrLoginUpdate(QrLoginStage.canceled));
  }

  /// 页面销毁：收尾并停止轮询。不碰任何已保存的凭据。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopPolling();
    service.abort();
    _out.close();
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  void _emit(QrLoginUpdate update) {
    _current = update;
    if (!_out.isClosed) {
      _out.add(update);
    }
  }
}
