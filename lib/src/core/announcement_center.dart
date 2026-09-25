import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'announcement.dart';
import 'store.dart';
import 'update_check.dart';
import 'vote.dart';

/// 公告中心：拉取、未读判定、弹窗队列、失败重试。
///
/// 拉取时机（用户 2026-09-25 定）：**启动 + 回前台 + 前台每 30 分钟**；
/// 后台不拉（会被系统掐、也费电），回前台补一次。
///
/// 网络恢复（用户要求「进应用时断网，恢复联网的那一刻要能立即拉」）：
/// 拉失败后进**失败态**，用一个探针按 `5s → 10s → 20s → 30s` 退避重试，
/// 一通就立刻重拉；探针只在前台、且只在失败态存在。
///
/// ⚠️ 拉取失败一律**静默**：不弹窗、不提示，只保持上一次的内容。
class AnnouncementCenter extends ChangeNotifier {
  AnnouncementCenter({
    required this.store,
    http.Client? client,
    String? baseUrl,
    String? version,
    String? platform,
  })  : _client = client,
        _baseUrl = baseUrl ?? kAnnouncementsBaseUrl,
        _versionOverride = version,
        _platformOverride = platform;

  /// 前台轮询间隔。
  static const Duration pollInterval = Duration(minutes: 30);

  /// 失败重试的退避序列，走完停在最后一档。
  static const List<Duration> retryBackoff = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  /// 已读 id 的保留上限，超了丢最旧的（避免文件无限长）。
  static const int _maxDismissed = 300;

  final Store store;
  final http.Client? _client;
  final String _baseUrl;
  final String? _versionOverride;
  final String? _platformOverride;

  List<Announcement> _items = const <Announcement>[];

  /// 关掉后永久不再弹（落盘）。
  final Set<String> _dismissed = <String>{};

  /// 关掉后本次运行不再弹（不落盘，重启就忘）。
  final Set<String> _sessionClosed = <String>{};

  /// poll_id → 已提交的选项，落盘。单选的「不让改票」靠它兜住。
  Map<String, List<String>> _voted = <String, List<String>>{};

  final List<Announcement> _popupQueue = <Announcement>[];

  String _deviceId = '';
  String _version = '';
  bool _loading = false;
  bool _failed = false;
  bool _foreground = false;
  bool _started = false;

  /// dispose 之后还在飞的那次拉取会回来 —— 它不能再 notify，也不能再排重试。
  /// 拉取是「发了不管」的，取消不了，只能在这里拦。
  bool _disposed = false;
  DateTime? _lastFetchAt;
  Timer? _pollTimer;
  Timer? _retryTimer;
  int _retryStep = 0;
  Future<void>? _inFlight;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 服务端当前下发的公告（已按平台 / 版本 / 时间过滤）。
  List<Announcement> get items => List<Announcement>.unmodifiable(_items);

  DateTime? get lastFetchAt => _lastFetchAt;

  bool get loading => _loading;

  /// 上一次拉取是失败的（界面据此提示「刷新失败」）。
  bool get failed => _failed;

  String get deviceId => _deviceId;

  /// 设置页入口右侧的角标用。
  int get unreadCount => _items.where((item) => !isDismissed(item.id)).length;

  bool isDismissed(String id) =>
      _dismissed.contains(id) || _sessionClosed.contains(id);

  bool hasVoted(String pollId) => _voted.containsKey(pollId);

  List<String> votedOptions(String pollId) =>
      _voted[pollId] ?? const <String>[];

  /// 启动时调一次：读盘 + 进入前台节奏。
  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    await _load();
    setForeground(true);
  }

  /// 前后台切换。回到前台立刻补拉一次，切到后台停掉轮询与探针。
  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    if (value) {
      _pollTimer ??= Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      unawaited(refresh());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  /// 拉一次。返回是否成功 —— 手动刷新据此决定要不要提示。
  Future<bool> refresh({bool manual = false}) async {
    if (_disposed) return false;
    final running = _inFlight;
    if (running != null) {
      // 手动刷新撞上在飞的自动拉取：等它落地再自己来一次，而不是直接说「失败」。
      if (!manual) return false;
      await running;
    }
    final task = _fetch();
    _inFlight = task;
    try {
      return await task;
    } finally {
      if (identical(_inFlight, task)) _inFlight = null;
    }
  }

  Future<bool> _fetch() async {
    _loading = true;
    _notify();
    final platform = _platform;
    final feed = await fetchAnnouncements(
      version: await _currentVersion(),
      platform: platform,
      client: _client,
      baseUrl: _baseUrl,
    );
    _loading = false;
    if (!feed.ok) {
      _failed = true;
      _scheduleRetry();
      _notify();
      return false;
    }
    _failed = false;
    _retryStep = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    _lastFetchAt = DateTime.now();
    final version = _version;
    _items = feed.items
        .where(
          (item) => item.visibleFor(
            version: version,
            platform: platform,
            now: _lastFetchAt!,
          ),
        )
        .toList();
    _rebuildPopupQueue();
    await _persist();
    _notify();
    return true;
  }

  /// 退避重试：只在失败态排一次，成功就取消。
  void _scheduleRetry() {
    if (_disposed || !_foreground) return;
    _retryTimer?.cancel();
    final delay = retryBackoff[_retryStep.clamp(0, retryBackoff.length - 1)];
    if (_retryStep < retryBackoff.length - 1) _retryStep += 1;
    _retryTimer = Timer(delay, () => unawaited(refresh()));
  }

  /// 攒出待弹的队列。**不可关闭的排前面** —— 必须处理的事先处理。
  void _rebuildPopupQueue() {
    final forced = <Announcement>[];
    final rest = <Announcement>[];
    for (final item in _items) {
      if (_popupQueue.any((queued) => queued.id == item.id)) continue;
      if (isDismissed(item.id)) continue;
      final poll = item.poll;
      // 投票已结束、或本机已经投过：这条公告不用再弹（但列表里还在）。
      if (poll != null && (!poll.open || hasVoted(poll.id))) continue;
      (item.forced ? forced : rest).add(item);
    }
    _popupQueue
      ..addAll(forced)
      ..addAll(rest);
  }

  /// 取下一条要弹的公告（出队）。弹窗由界面层一条一条走。
  Announcement? takeNextPopup() {
    if (_popupQueue.isEmpty) return null;
    return _popupQueue.removeAt(0);
  }

  /// 关掉一条公告。
  ///
  /// [force] 只给「不可关闭的公告已无意义」那种情况用（已是最新版 / 内测版）——
  /// 其余情况对不可关闭的公告调这里等于没动，免得把强制更新悄悄漏掉。
  Future<void> dismiss(Announcement announcement, {bool force = false}) async {
    if (announcement.forced && !force) return;
    _popupQueue.removeWhere((item) => item.id == announcement.id);
    if (announcement.sessionOnly && !force) {
      _sessionClosed.add(announcement.id);
    } else {
      _dismissed.add(announcement.id);
      while (_dismissed.length > _maxDismissed) {
        _dismissed.remove(_dismissed.first);
      }
    }
    await _persist();
    _notify();
  }

  /// 投一票。成功后记下 poll_id（单选不给改票入口），并把它从弹窗队列里摘掉。
  Future<bool> vote(Announcement announcement, List<String> options) async {
    final poll = announcement.poll;
    if (poll == null || options.isEmpty || hasVoted(poll.id)) return false;
    final accepted = await submitVote(
      pollId: poll.id,
      deviceId: _deviceId,
      options: options,
      client: _client,
      baseUrl: _baseUrl,
    );
    if (!accepted) return false;
    _voted[poll.id] = List<String>.of(options);
    _popupQueue.removeWhere((item) => item.id == announcement.id);
    await _persist();
    _notify();
    return true;
  }

  /// 平台参数。只有安卓与 Windows 两条发行线，其余平台不带（等于不限平台）。
  String get _platform {
    final override = _platformOverride;
    if (override != null) return override;
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return '';
  }

  Future<String> _currentVersion() async {
    final override = _versionOverride;
    if (override != null) {
      _version = override;
      return override;
    }
    if (_version.isEmpty) _version = await readCurrentVersion();
    return _version;
  }

  Future<void> _load() async {
    final json = await store.loadAnnouncementState();
    if (json != null) {
      final dismissed = json['dismissed'];
      if (dismissed is List) {
        _dismissed
          ..clear()
          ..addAll(dismissed.whereType<String>());
      }
      final voted = json['voted'];
      if (voted is Map) {
        _voted = <String, List<String>>{
          for (final entry in voted.entries)
            if (entry.value is List)
              '${entry.key}':
                  (entry.value as List).whereType<String>().toList(),
        };
      }
      final device = json['device_id'];
      if (device is String) _deviceId = device.trim();
    }
    if (_deviceId.isEmpty) {
      _deviceId = newDeviceId();
      await _persist();
    }
  }

  /// 落盘。⚠️ 单独一个 `announcement_state.json`，**不进 `settings.json`** ——
  /// 进去会连带进 `.bcbak`，还会把设置页的「未保存」判定搅乱。
  Future<void> _persist() async {
    try {
      await store.saveAnnouncementState(<String, dynamic>{
        'version': 1,
        'device_id': _deviceId,
        'dismissed': _dismissed.toList(),
        'voted': _voted,
      });
    } catch (_) {
      // 落盘失败只影响「下次启动还认不认得已读」，不值得打断用户。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }
}
