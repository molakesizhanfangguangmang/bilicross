import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'core/abort.dart';
import 'core/bili_api.dart';
import 'core/downloader.dart';
import 'core/log_store.dart';
import 'core/models.dart';
import 'core/preflight.dart';
import 'core/muxer.dart';
import 'core/parser.dart';
import 'core/signing.dart';
import 'core/store.dart';
import 'i18n/app_localizations.dart';
import 'i18n/app_localizations_zh.dart';

/// 同名目标的落点。[renamed] 为真表示走了「加编号」分支，调用方据此计数。
typedef _DuplicateTarget = ({String candidate, String path, bool renamed});

class AppState extends ChangeNotifier {
  AppState._(this.store, this.settings, this.cookie, this.token, this.tasks) {
    persistedSettingsJson = jsonEncode(settings.toJson());
    api = _buildApi();
    parseService = ParseService(api: api, settings: settings);
    downloader = StreamDownloader(
      userAgent: settings.userAgent,
      proxy: settings.proxy,
    );
  }

  /// 仅测试用：注入依赖建实例，不走 [AppState.load]（那条会读写真实用户数据目录）。
  /// 配合 `Store.at(临时目录)` 用。
  @visibleForTesting
  static AppState forTest({
    required Store store,
    required AppSettings settings,
    WebCookie cookie = const WebCookie.empty(),
    AppToken? token,
    List<DownloadTask>? tasks,
  }) =>
      AppState._(store, settings, cookie, token, tasks ?? <DownloadTask>[]);

  /// [isWindows] 只给测试用：真机不传。见 [Store.open] 的说明。
  static Future<AppState> load({bool? isWindows}) async {
    final store = await Store.open(isWindows: isWindows);
    final settings = await store.loadSettings();
    final l10n = AppLocalizations.fromCode(settings.localeCode);
    if (settings.downloadDir.trim().isEmpty) {
      settings.downloadDir = '${store.root.path}${Platform.pathSeparator}downloads';
    }
    final credentials = await store.loadCredentials();
    final tasks = await store.loadTasks();
    for (final task in tasks) {
      if (task.stage == TaskStage.downloading ||
          task.stage == TaskStage.muxing ||
          task.stage == TaskStage.resolving) {
        task.stage = TaskStage.pending;
        task.message = l10n.tr('msg.interruptedOnExit');
        // CDN 地址带时效，续传前必须重新解析，不能沿用上次的地址。
        task.videoUrl = '';
        task.audioUrl = '';
      } else if (task.stage == TaskStage.paused) {
        // 暂停的任务留在暂停态：分片还在，等着用户点「继续」。
        // 地址同样过期，继续时会重新解析，分片照样按断点接。
        task.message = l10n.tr('msg.pausedOnExit');
        task.videoUrl = '';
        task.audioUrl = '';
      }
    }
    await LogStore.instance.attach(store.root);
    LogStore.instance.add('启动', '逸轨 启动');
    LogStore.instance.add(
      '启动',
      '默认画质 ${settings.preferredQuality}｜并发 ${settings.maxParallelTasks}'
      '｜分段 ${settings.partsPerFile}｜优先 APP ${settings.preferAppApi ? '开' : '关'}'
      '｜WEB Cookie ${credentials.cookie.isEmpty ? '无' : '有'}'
      '｜APP Token ${credentials.token == null ? '无' : '有'}'
      '｜代理 ${settings.proxy.trim().isEmpty ? '直连' : '已配置'}'
      '｜日志文件 ${LogStore.instance.filePath ?? '不可用'}',
    );
    return AppState._(store, settings, credentials.cookie, credentials.token, tasks);
  }
  final Store store;
  AppSettings settings;

  /// 最近一次**落盘**的设置内容（JSON）。
  ///
  /// ⚠️ 设置页的「有没有未保存的改动」拿它当基线，而不是「进页面时拍个快照」——
  /// 设置页在 IndexedStack 里是常驻的，进页面根本触发不了初始化，
  /// 快照会拍成 app 启动时的状态，判定就不准了。
  String persistedSettingsJson = '';
  WebCookie cookie;
  AppToken? token;
  final List<DownloadTask> tasks;

  /// 正在运行的任务各自的取消句柄。暂停/强制结束按任务 id 找它，
  /// 它同时握着当前连接，取消时先掐连接再让各层按取消收场。
  final Map<String, AbortControl> _controls = <String, AbortControl>{};

  late BiliApi api;
  late ParseService parseService;
  late StreamDownloader downloader;

  /// 当前语言的文案。任务消息、异常提示这些没有 BuildContext 的地方都从这里取，
  /// 所以换语言之后新产生的消息立刻是新语言；已经写进任务的历史消息不回译。
  AppLocalizations get l10n => AppLocalizations.fromCode(settings.localeCode);

  AccountState account = const AccountState.unknown();
  ParsedMedia? parsed;
  String addressInput = '';

  /// 当前解析结果所属的合集清单；不在合集里时为 null。
  ///
  /// 清单直接来自 `view` 的 `ugc_season`，所以「列出整部合集」不额外发请求。
  SeasonManifest? get manifest => parsed?.info.season;
  String notice = '';
  bool busy = false;
  bool queueRunning = false;
  String? ffmpegPath;

  /// 最近一次从下载页入队的那批任务 id（只存内存，重启即忘，不落盘）。
  ///
  /// 任务页切进来时用它决定默认落在哪一栏：用户刚点过「加入任务 / 立即下载」，
  /// 就把他带到与这批任务当前状态相符的栏，而不是永远停在「等待下载」。
  /// ⚠️ 只在入队时赋值、**不发通知** —— 它不是界面状态，只是给任务页的一次性
  /// 线索，别掺进通知边界。
  Set<String> _recentEnqueued = const <String>{};

  /// 最近一次入队的那批任务 id（只读，任务页用）。
  Set<String> get recentEnqueuedIds => _recentEnqueued;

  AppAuthCode? pendingAuth;
  String authStatus = '';
  Timer? _authTimer;
  DateTime? _authDeadline;

  BiliApi _buildApi() => BiliApi(settings: settings);

  Future<void> _rebuildApi() async {
    api.close();
    api = _buildApi();
    parseService = ParseService(api: api, settings: settings);
    downloader = StreamDownloader(
      userAgent: settings.userAgent,
      proxy: settings.proxy,
    );
  }

  // ---------- 界面通知边界 ----------
  //
  // AppState 是个「粗通知源」：50 多处 notifyListeners()，监听者只知道「有东西变了」，
  // 只能整页重建。其中最密的是任务字节进度（每个任务每秒最多 10 次，并发任务还会叠），
  // 而外壳重建一次要重算 ThemeData 与整列导航、任务页重建一次要摊平整个列表 ——
  // 都不该由一次进度回调付账。
  //
  // 这里**不在那 50 多个通知点上逐个分类**，而是把通知过滤成界面真正关心的几路。
  // 分类的失败方式是「漏标一处 → 某个控件再也不刷新」，那是本项目最难查的回归；
  // 过滤的失败方式最多是「多刷了一次」。两者不对称，所以选过滤。

  /// 本次通知是否只改了任务的字节进度。仅在 [notifyListeners] 派发期间为真。
  bool _progressOnly = false;

  /// 通知界面：任务字节进度有更新。
  ///
  /// 与 [notifyListeners] 分开的唯一理由是让不看进度的界面（见 [stableView]）
  /// 能免疫这一路最高频的通知；通知的到达时机与频率都没变。
  void _notifyProgress() {
    _progressOnly = true;
    try {
      notifyListeners();
    } finally {
      _progressOnly = false;
    }
  }

  /// 外壳（MaterialApp、顶栏、导航）订阅这个。
  ///
  /// 只有快照里的几项变了才通知 —— 其余（进度、busy、notice、任务增删、预检结果……）
  /// 全部挡在外面。
  ///
  /// ⚠️ 外壳 build 期间多读一项可变状态，就把那一项加进快照
  /// （见 `main.dart` 的 `_buildApp` 与 `_AppShellState.build`），否则那一项变了
  /// 外壳不会重建。
  late final Listenable shellView = _StateView(
    this,
    snapshot: () => (
      locale: settings.localeCode,
      theme: settings.themeId,
      queue: queueRunning,
      risk: _riskControlHit,
      splashSeconds: settings.splashSeconds,
    ),
  );

  /// 不含任务字节进度的订阅对象：给**不显示逐任务进度**的界面用
  /// （下载页、账号页、设置页、选集页）。**任务页要显示进度，必须直接订阅
  /// AppState 本身**，换到这里进度就停更了。
  late final Listenable stableView = _StateView(this, ignoreProgress: true);

  // ---------- 设置 ----------

  Future<void> saveSettings() async {
    await store.saveSettings(settings);
    persistedSettingsJson = jsonEncode(settings.toJson());
    await _rebuildApi();
    await refreshFfmpeg();
    notifyListeners();
  }

  /// 恢复备份之后重新读盘并重新验证。
  ///
  /// 恢复是覆盖式的：内存里的设置、凭据与任务必须整体换成磁盘上的新内容，
  /// 否则界面还显示恢复前的账号。凭据过期时保留其它配置，账号状态回到「需要重新登录」，
  /// 不在这里清空设置或任务。
  Future<void> reloadAfterRestore() async {
    final restored = await store.loadSettings();
    if (restored.downloadDir.trim().isEmpty) {
      restored.downloadDir =
          '${store.root.path}${Platform.pathSeparator}downloads';
    }
    settings = restored;
    persistedSettingsJson = jsonEncode(settings.toJson());
    final credentials = await store.loadCredentials();
    cookie = credentials.cookie;
    token = credentials.token;
    tasks
      ..clear()
      ..addAll(await store.loadTasks());
    account = const AccountState.unknown();
    parsed = null;
    await _rebuildApi();
    await refreshFfmpeg();
    notifyListeners();
    // 重新验证：Cookie 与 Token 有效就刷新账号状态，失效就停在「未登录」，不抛错给用户。
    await refreshAccount();
  }

  /// 正在跑的任务数（解析中 / 下载中 / 合并中）。退出前用它判断要不要二次确认。
  int get activeTaskCount => tasks
      .where((task) =>
          task.stage == TaskStage.resolving ||
          task.stage == TaskStage.downloading ||
          task.stage == TaskStage.muxing)
      .length;

  /// 暂停全部正在跑的任务（托盘菜单用）。暂停保留分片，之后可以继续；
  /// 不会把用户主动暂停记成下载失败。
  void pauseAllActive() {
    for (final task in tasks) {
      if (task.stage == TaskStage.resolving ||
          task.stage == TaskStage.downloading ||
          task.stage == TaskStage.muxing) {
        pauseTask(task.id);
      }
    }
    notifyListeners();
  }

  /// 任务页「下载中」栏的「全部暂停」。
  void pauseAllTasks() => pauseAllActive();

  /// 任务页「下载中」栏的「全部终止」：中止在跑的（含解析中），连分片一起清。
  void stopRunningTasks() {
    for (final task in List<DownloadTask>.of(tasks)) {
      if (task.stage == TaskStage.resolving ||
          task.stage == TaskStage.downloading ||
          task.stage == TaskStage.muxing) {
        stopTask(task.id);
      }
    }
    notifyListeners();
  }

  /// 任务页「等待下载」栏的「全部终止」：放弃等待中的任务。
  /// 失败的不动 —— 留着重试；已完成的也不动 —— 那是「已下载」栏的事。
  void stopWaitingTasks() {
    for (final task in List<DownloadTask>.of(tasks)) {
      if (task.stage == TaskStage.pending) {
        task.stage = TaskStage.stopped;
      }
    }
    _persistTasks();
    notifyListeners();
  }

  /// 任务页「已下载」栏的「全部清理」：只移除已完成任务的记录，
  /// 不碰磁盘上已经下好的文件。失败的任务不在这里，不受影响。
  void removeDoneTasks() {
    tasks.removeWhere((task) => task.stage == TaskStage.done);
    _persistTasks();
    notifyListeners();
  }

  // ---------- 段级控制（任务列表的段行用） ----------
  //
  // 一集一个任务，段只是**显示与控制粒度**，不是队列单位 —— 执行仍按清单串行。
  // 这三个方法只动传进来的那些任务，不碰别的段。

  /// 暂停一组正在跑的任务。
  void pauseTasks(Iterable<String> ids) {
    for (final id in ids) {
      pauseTask(id);
    }
  }

  /// 终止一组任务：在跑的连分片一起清，等待中的直接放弃。
  /// 已完成的与失败的不动 —— 前者没意义，后者留着重试。
  void stopTasks(Iterable<String> ids) {
    final wanted = ids.toSet();
    var touchedIdle = false;
    for (final task in List<DownloadTask>.of(tasks)) {
      if (!wanted.contains(task.id)) continue;
      if (_isRunning(task.stage)) {
        stopTask(task.id);
      } else if (task.stage == TaskStage.pending) {
        task.stage = TaskStage.stopped;
        touchedIdle = true;
      } else if (task.stage == TaskStage.paused) {
        // 暂停的任务已经没有活着的取消句柄了（_runTask 的 finally 收走了），
        // 分片得自己删，否则「终止」看着成功、文件却留在盘上。
        unawaited(_stopPaused(task));
      }
    }
    if (touchedIdle) {
      _persistTasks();
      notifyListeners();
    }
  }

  /// 终止一个已暂停的任务：删掉分片与半成品，与 [_finishAborted] 的强制结束一致。
  Future<void> _stopPaused(DownloadTask task) async {
    var removed = await removeArtifacts(task.videoPath);
    removed += await removeArtifacts(task.audioPath);
    removed += await removeArtifacts(task.outputPath);
    task.stage = TaskStage.stopped;
    task.message = l10n.tr('msg.stopped', {'count': '$removed'});
    _riskPaused.remove(task.id);
    _invalidateMergeReady();
    await store.saveTasks(tasks);
    LogStore.instance.add('任务', '${task.title}：强制结束，已删除 $removed 个残留文件');
    notifyListeners();
  }

  /// 把一组任务放回队列并开跑（段行的「重试」）。
  ///
  /// 在跑的与已完成的跳过；档位与编码保留，只清掉可能过期的 CDN 地址。
  /// 批量只走一次 [pumpQueue]，不是每个任务各起一次。
  void retryTasks(Iterable<String> ids) {
    final wanted = ids.toSet();
    var changed = false;
    for (final task in tasks) {
      if (!wanted.contains(task.id)) continue;
      if (_isRunning(task.stage) || task.stage == TaskStage.done) continue;
      task.stage = TaskStage.pending;
      task.message = l10n.tr('msg.waitRetry');
      task.receivedBytes = 0;
      task.totalBytes = 0;
      task.merged = false;
      task.videoUrl = '';
      task.audioUrl = '';
      changed = true;
    }
    if (!changed) return;
    _persistTasks();
    notifyListeners();
    unawaited(pumpQueue());
  }

  // ---------- 批量清理（任务页顶部按钮用） ----------

  /// 清空任务列表（不分状态）。
  ///
  /// [removeFiles] 为真时连残留文件一起删 —— 但**只删非完成任务**留下的分片与
  /// 半成品，已下载完成的成品一律不动：「清空列表」不该顺手把下好的东西删掉。
  ///
  /// 正在跑的任务不在这里处理，调用方应先确认（界面在 `activeTaskCount > 0`
  /// 时把按钮禁掉），否则文件还在写，删了也没意义。
  Future<int> clearAllTasks({required bool removeFiles}) async {
    var removed = 0;
    if (removeFiles) {
      for (final task in tasks) {
        if (task.stage == TaskStage.done) continue;
        removed += await _removeTaskFiles(task);
      }
    }
    final count = tasks.length;
    tasks.clear();
    await store.saveTasks(tasks);
    LogStore.instance.add(
      '任务',
      removeFiles
          ? '清空任务列表（$count 条），并删除 $removed 个残留文件'
          : '清空任务列表（$count 条）',
    );
    notifyListeners();
    return removed;
  }

  /// 清理残留：删掉**非完成任务**留下的分片与半成品，任务记录保留。
  ///
  /// 已下载完成的成品不在清理范围内；正在跑的任务也不动（文件还在写）。
  Future<int> cleanupResidue() async {
    var removed = 0;
    for (final task in tasks) {
      if (task.stage == TaskStage.done || _isRunning(task.stage)) continue;
      removed += await _removeTaskFiles(task);
    }
    await store.saveTasks(tasks);
    LogStore.instance.add('任务', '清理残留：删除 $removed 个文件');
    notifyListeners();
    return removed;
  }

  /// 删一个任务留下的分片与半成品。已合并的成品不删 —— 那是用户要的东西。
  Future<int> _removeTaskFiles(DownloadTask task) async {
    var removed = await removeArtifacts(task.videoPath);
    removed += await removeArtifacts(task.audioPath);
    if (!task.merged) {
      removed += await removeArtifacts(task.outputPath);
    }
    _invalidateMergeReady();
    return removed;
  }

  // ---------- 风控（-352） ----------

  /// 撞到风控时置位，界面据此弹一次提示。
  ///
  /// 预检与下载共用同一套处理：**停手 + 提示 + 手动恢复**，
  /// 不等冷却、不自动重试、不把已下好的部分丢掉。
  bool _riskControlHit = false;

  bool get riskControlHit => _riskControlHit;

  /// 因风控被暂停的任务 id。恢复时只放这些回队列，
  /// 不碰用户自己按「暂停」停下的那些。
  final Set<String> _riskPaused = <String>{};

  /// 界面侧（如空间入口拉清单失败）设一句提示，走与解析同一处展示位。
  void showNotice(String text) {
    notice = text;
    notifyListeners();
  }

  /// 界面弹过提示、用户选了「先放着」：只清标记。
  /// 队列不会因此自己跑起来 —— 要动还是得用户点任务页的开始/继续。
  void dismissRiskControl() {
    if (!_riskControlHit) return;
    _riskControlHit = false;
    notifyListeners();
  }

  /// 风控后的恢复：清标记，把因风控暂停的任务放回队列。
  ///
  /// 从停下的那一集接着走 —— 已完成的集不是 pending，本来就不会重跑；
  /// 分片留在盘上，续传照旧。
  void resumeAfterRiskControl() {
    _riskControlHit = false;
    final ids = List<String>.of(_riskPaused);
    _riskPaused.clear();
    for (final task in tasks) {
      if (!ids.contains(task.id)) continue;
      task.stage = TaskStage.pending;
      task.message = l10n.tr('msg.waitRetry');
      task.receivedBytes = 0;
      task.totalBytes = 0;
      task.merged = false;
      task.videoUrl = '';
      task.audioUrl = '';
    }
    _persistTasks();
    notifyListeners();
    unawaited(pumpQueue());
  }

  /// 切换界面语言：改设置、落盘、通知监听者重建 MaterialApp。
  /// 不重启应用，也不重建任务与凭据，只影响文案。
  /// 非法代码直接忽略——磁盘上的旧数据归一化交给 fromJson，这里不该把
  /// 「传错值」翻译成「切回中文」，那会覆盖用户已选的语言。
  Future<void> setLocale(String code) async {
    if (code != kLocaleSystem && code != kLocaleZhCN && code != kLocaleEnUS) {
      return;
    }
    if (code == settings.localeCode) return;
    settings.localeCode = code;
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> refreshFfmpeg() async {
    ffmpegPath = await Muxer.locate(settings.ffmpegPath);
    notifyListeners();
  }

  // ---------- 凭据 ----------

  Future<void> applyCookieText(String text) async {
    final parsedCookie = CookieParser.parse(text);
    if (parsedCookie.isEmpty) {
      throw BiliException(l10n.tr('err.noSessdata'));
    }
    cookie = parsedCookie;
    await store.saveCredentials(CredentialBundle(cookie: cookie, token: token));
    LogStore.instance.add(
      '账号',
      'WEB Cookie 已写入：SESSDATA ${parsedCookie.sessData.length} 字符'
      '｜bili_jct ${parsedCookie.biliJct.isEmpty ? '无' : '有'}'
      '｜DedeUserID ${parsedCookie.dedeUserId.isEmpty ? '无' : '有'}',
    );
    notice = parsedCookie.isComplete
        ? l10n.tr('notice.cookieWritten')
        : l10n.tr('notice.cookieWrittenMissing', {
            'fields':
                '${parsedCookie.biliJct.isEmpty ? 'bili_jct ' : ''}'
                '${parsedCookie.dedeUserId.isEmpty ? 'DedeUserID' : ''}',
          });
    notifyListeners();
    await refreshAccount();
  }

  Future<void> clearCookie() async {
    cookie = const WebCookie.empty();
    await store.saveCredentials(CredentialBundle(cookie: cookie, token: token));
    account = AccountState(loggedIn: false, message: l10n.tr('notice.cookieCleared'));
    LogStore.instance.add('账号', 'WEB Cookie 已清除');
    notifyListeners();
  }

  Future<void> refreshAccount() async {
    if (cookie.isEmpty) {
      account = AccountState(loggedIn: false, message: l10n.tr('notice.noCookie'));
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      account = await api.fetchAccount(cookie.raw);
      if (account.loggedIn) {
        LogStore.instance.add(
          '账号',
          'WEB 账号：${account.uname}（mid=${account.mid}）'
          '｜大会员 ${account.vipStatus == 1 ? '是' : '否'}'
          '（WEB 账号状态，最终以 APP 模式解析为准）',
        );
      } else {
        LogStore.instance.add('账号', 'WEB 账号不可用：${account.message}');
      }
    } on Exception catch (error) {
      account = AccountState(loggedIn: false, message: '$error');
      LogStore.instance.add('账号', 'WEB 账号检测失败：$error');
    }
    busy = false;
    notifyListeners();
  }

  // ---------- APP Token ----------

  Future<void> startAppAuth() async {
    if (cookie.isEmpty) {
      throw BiliException(l10n.tr('err.needWebCookie'));
    }
    pendingAuth = await api.requestAppAuthCode();
    authStatus = l10n.tr('auth.waiting');
    _authDeadline = DateTime.now().add(const Duration(minutes: 5));
    _authTimer?.cancel();
    _authTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollAuth());
    notifyListeners();
  }

  Future<void> cancelAppAuth() async {
    _authTimer?.cancel();
    _authTimer = null;
    pendingAuth = null;
    authStatus = '';
    notifyListeners();
  }

  Future<void> _pollAuth() async {
    final auth = pendingAuth;
    if (auth == null) return;
    if (_authDeadline != null && DateTime.now().isAfter(_authDeadline!)) {
      await cancelAppAuth();
      authStatus = l10n.tr('auth.timeout');
      notifyListeners();
      return;
    }
    try {
      final outcome = await api.pollAppAuthCode(auth.code);
      switch (outcome.status) {
        case AppPollStatus.pending:
          return;
        case AppPollStatus.success:
          token = outcome.token;
          await store.saveCredentials(CredentialBundle(cookie: cookie, token: token));
          _authTimer?.cancel();
          _authTimer = null;
          pendingAuth = null;
          authStatus = l10n.tr('auth.tokenReady');
          LogStore.instance.add(
            '账号',
            'APP Token 已获取：mid=${token?.mid ?? 0}'
            '｜有效期 ${token?.expiresIn ?? 0} 秒',
          );
          notifyListeners();
        case AppPollStatus.expired:
        case AppPollStatus.failed:
          _authTimer?.cancel();
          _authTimer = null;
          authStatus = outcome.message;
          notifyListeners();
      }
    } on Exception catch (error) {
      authStatus = l10n.tr('auth.pollFailed', {'error': '$error'});
      notifyListeners();
    }
  }

  // ---------- 解析 ----------

  /// 从空间链接 / lists 链接拉到的合集，等用户在首页点进选集页。
  ///
  /// ⚠️ **不直接跳选集页**：跟「视频链接带合集」那条路一致 —— 首页先给一张
  /// 入口卡片（标题 + 集数/段数），用户点进去才铺清单。
  SeasonManifest? pendingSeason;

  /// 首页展示一张合集入口卡片。会清掉上一次的解析结果与预检缓存。
  void showSeasonEntry(SeasonManifest manifest) {
    pendingSeason = manifest;
    parsed = null;
    notice = '';
    resetPreflight();
    LogStore.instance.add(
      '解析',
      '合集入口：${manifest.title.isEmpty ? '未命名' : manifest.title}'
      '（${manifest.totalEpisodes} 集 / ${manifest.sections.length} 段）',
    );
    notifyListeners();
  }

  /// 解析一个地址。
  ///
  /// [pageOverride] 用来指定多 P 视频里的第几个分 P：不带就按地址里的 `?p=`
  /// （没有 `?p=` 就是第 1 P）。下载页的「选集」走这条。
  Future<void> parseAddress(String input, {int? pageOverride}) async {
    addressInput = input;
    busy = true;
    parsed = null;
    // 换地址了：上一次的空间/lists 合集入口卡片不该继续挂着。
    pendingSeason = null;
    notice = '';
    // 换了清单：旧的预检结果不能串到新合集上。
    resetPreflight();
    LogStore.instance.add(
      '解析',
      pageOverride == null ? '地址：$input' : '地址：$input（指定第 $pageOverride P）',
    );
    notifyListeners();
    try {
      parsed = await parseService.parseTarget(
        input,
        cookie: cookie,
        token: token ?? _emptyToken,
        pageOverride: pageOverride,
      );
      // 档位够不够不再提示：片源没有这一档是常态（设置里选的是最高档），
      // 界面把实际拿到的流列出来就是事实，不需要额外说一句。
      notice = '';
      final media = parsed!;
      LogStore.instance.add(
        '解析',
        '通道 ${media.channel}｜视频档位 ${media.videos.map((item) => item.id).join('/')}'
        '｜音频档位 ${media.audios.map((item) => item.id).join('/')}'
        '｜请求档位 ${settings.preferredQuality}',
      );
    } on Exception catch (error) {
      notice = authNotice(error) ?? '$error';
      LogStore.instance.add('解析', '解析失败：$error');
    }
    busy = false;
    notifyListeners();
  }

  /// 凭据失效只认明确的「未登录 / 未授权」信号：REST 的 `-101`，或 gRPC 的
  /// UNAUTHENTICATED（`grpc-status=16`）。风控 `-352`、参数错误、网络失败都不算，
  /// 否则会把人往「重新登录」上引，而重新登录并不能解决那些问题。
  /// 本来就没有的凭据也谈不上失效，所以只在这条凭据存在时才报。
  ///
  /// 纯函数，方便离线自测；要读当前 cookie/token 状态的调用点用 [authNotice]。
  static String? authNoticeFor(
    Object error, {
    required bool hasCookie,
    required bool hasToken,
    AppLocalizations? l10n,
  }) {
    final t = l10n ?? const AppLocalizationsZh();
    final text = '$error';
    final code = error is BiliException ? error.code : null;
    final grpcUnauthorized =
        text.contains('grpc-status=16') || text.contains('UNAUTHENTICATED');
    if (code != -101 && !grpcUnauthorized) return null;
    // gRPC 只有 APP Token 一条路；REST 的 -101 优先归给 Cookie，没有才看 Token。
    if (grpcUnauthorized) return hasToken ? t.tr('notice.tokenInvalid') : null;
    if (hasCookie) return t.tr('notice.cookieInvalid');
    if (hasToken) return t.tr('notice.tokenInvalid');
    return null;
  }

  String? authNotice(Object error) {
    final text = authNoticeFor(
      error,
      hasCookie: !cookie.isEmpty,
      hasToken: token?.accessToken.isNotEmpty ?? false,
      l10n: l10n,
    );
    if (text != null) {
      LogStore.instance.add('账号', '$text｜原因：$error');
    }
    return text;
  }

  static const AppToken _emptyToken = AppToken(
    accessToken: '',
    refreshToken: '',
    expiresIn: 0,
    mid: 0,
    obtainedAtMs: 0,
  );

  // ---------- 任务 ----------

  /// 把一条解析结果加入队列，返回新建的任务（视频与音频都为空时返回 null）。
  ///
  /// **参数化而非读全局 [parsed]**：清单批量入队时每一项都有自己的解析结果，
  /// 全局单例只存得下最后一个，若沿用单例会让整批任务全指向同一集。
  DownloadTask? enqueueItem({
    required ParsedMedia media,
    required MediaStream? video,
    required MediaStream? audio,
    required String engine,
    String? source,
  }) {
    if (video == null && audio == null) return null;
    final dir = settings.downloadDir;
    final name = sanitizeFileName(
      '${media.info.title}${media.page.page > 1 ? ' P${media.page.page} ${media.page.part}' : ''}',
    );
    final task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: name,
      source: source ?? addressInput,
      infoId: media.info.bvid.isEmpty ? '${media.info.aid}' : media.info.bvid,
      page: media.page.page,
      cid: media.page.cid,
      outputPath: '$dir${Platform.pathSeparator}$name.${video == null ? 'm4a' : 'mp4'}',
      engine: engine,
      channel: media.channel,
      videoUrl: video?.url ?? '',
      audioUrl: audio?.url ?? '',
      videoBackups: video?.backupUrls ?? const [],
      audioBackups: audio?.backupUrls ?? const [],
      // 档位与编码一起记下来：重试时按这对值取流，不改成列表里的第一条。
      videoQualityId: video?.id ?? 0,
      audioQualityId: audio?.id ?? 0,
      videoCodecs: video?.codecs ?? '',
      audioCodecs: audio?.codecs ?? '',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    tasks.insert(0, task);
    // 单条入队也记进「最近一批」：任务页据此决定切进去时落在哪一栏。
    _recentEnqueued = <String>{task.id};
    _persistTasks();
    LogStore.instance.add('任务', '入队：${task.title}（等待开始）');
    notifyListeners();
    return task;
  }

  /// 单集入队：用当前解析结果（[parsed]）走 [enqueueItem]。
  ///
  /// 只在「清单里只有一项」或用户手动选流的场景用；清单批量入队请直接调
  /// [enqueueItem]，把每一项自己的解析结果传进去。
  void enqueue({
    required MediaStream? video,
    required MediaStream? audio,
    required String engine,
  }) {
    final media = parsed;
    if (media == null) return;
    enqueueItem(media: media, video: video, audio: audio, engine: engine);
  }

  /// 路径比较键：Windows 文件系统不区分大小写，比较前统一成小写正斜杠。
  static String _pathKey(String path) => Platform.isWindows
      ? path.replaceAll('\\', '/').toLowerCase()
      : path;

  /// 两位序号：1 -> 01，25 -> 25。
  static String _pad2(int value) => value.toString().padLeft(2, '0');

  /// 同名目标定名。返回 null 表示 `skip` 模式下这一条不登记。
  ///
  /// [dir] / [stem] / [extension] 由调用方按各自的落点给（合集落子目录、`.m4a`
  /// 还是 `.mp4` 只有调用方知道），这里只负责查重与加编号。
  _DuplicateTarget? _resolveDuplicatePath({
    required String dir,
    required String stem,
    required String extension,
    required Set<String> taken,
  }) {
    final separator = Platform.pathSeparator;
    var candidate = '$dir$separator$stem';
    var finalPath = '$candidate.$extension';

    if (!taken.contains(_pathKey(finalPath))) {
      return (candidate: candidate, path: finalPath, renamed: false);
    }

    switch (settings.duplicateMode) {
      case kDuplicateSkip:
        return null;
      case kDuplicateRename:
        // 001 标题.mp4 撞了就试 001 标题 (1).mp4、(2)…… 编号挂在扩展名前，
        // 所有临时文件从同一个 stem 派生，恢复下载才对得上。
        var attempt = 1;
        var renamedStem = stem;
        while (true) {
          renamedStem = '$stem ($attempt)';
          finalPath = '$dir$separator$renamedStem.$extension';
          if (!taken.contains(_pathKey(finalPath))) break;
          attempt += 1;
        }
        return (
          candidate: '$dir$separator$renamedStem',
          path: finalPath,
          renamed: true,
        );
      case kDuplicateOverwrite:
      default:
        // 覆盖：沿用原名，等任务开下时由下载器写穿旧文件。
        return (candidate: candidate, path: finalPath, renamed: false);
    }
  }

  /// 批量把清单里勾中的集登记进队列。
  ///
  /// **只登记、不解析**：每集的 playurl 要按各自的 cid 单独取，一整部合集
  /// 一口气解析既慢又容易触发风控。任务以 videoUrl 为空的状态入队，开跑时
  /// [_runTask] 走 resolving 阶段按 source（每集自己的 bvid 地址）逐个解析 ——
  /// 与「地址过期重试」走的是同一条路。
  ///
  /// 同名处理按 [AppSettings.duplicateMode]：
  /// - `skip`：磁盘或队列里已有同名目标就不登记，计入 skipped；
  /// - `overwrite`：照常登记（覆盖发生在任务真正开下时，排队期间不动旧文件）；
  /// - `rename`：保留旧文件，新文件名加递增编号，且任务的所有临时文件
  ///   都从这份新名派生，恢复下载才不会对不上。
  ///
  /// 同名判断同时查**磁盘**与**当前队列**（含本批次前面刚登记的），避免同批
  /// 或跨批产生路径冲突。全程不弹窗，统计结果由调用方统一展示。
  DuplicateBatchOutcome enqueueEpisodes({
    required SeasonManifest manifest,
    required Set<int> selectedPages,
    required String engine,
    Map<int, int> qualityOverrides = const <int, int>{},
  }) {
    final batchId = 'batch-${DateTime.now().microsecondsSinceEpoch}';
    final dir = settings.downloadDir;
    final separator = Platform.pathSeparator;
    final seasonFolder = sanitizeFileName(manifest.title);
    final seasonDir = '$dir$separator$seasonFolder';

    // 队列里已有任务占用的路径（规范化后），本批次新登记的也会持续并入。
    final taken = <String>{
      for (final task in tasks) _pathKey(task.outputPath),
    };

    var enqueued = 0;
    var skipped = 0;
    var renamed = 0;
    final now = DateTime.now();
    final enqueuedIds = <String>{};

    for (final section in manifest.sections) {
      for (final episode in section.episodes) {
        if (!selectedPages.contains(episode.page)) continue;
        // 未通过预检的集不加入 —— 设计定案要求「未预检完的集不给下载」。
        // 缺档 / 不可用 / 风控都由预检阶段标记，这里只认 downloadable。
        final preflight = preflightOf(episode.page);
        if (!preflight.downloadable) {
          skipped += 1;
          continue;
        }
        // 单集覆盖档位：只有这一集例外，其余集仍按预检给的实际最高档走。
        final video = preflight.videoFor(qualityOverrides[episode.page]);
        final stem = sanitizeFileName('${_pad2(episode.page)} ${episode.title}');
        final target = _resolveDuplicatePath(
          dir: seasonDir,
          stem: stem,
          extension: episode.bvid.isEmpty ? 'm4a' : 'mp4',
          taken: taken,
        );
        if (target == null) {
          skipped += 1;
          continue;
        }
        if (target.renamed) renamed += 1;
        final candidate = target.candidate;
        final finalPath = target.path;

        final task = DownloadTask(
          id: '${now.microsecondsSinceEpoch}-${episode.page}',
          title: candidate.split(separator).last,
          // source 存每集自己的地址：重解析按它走，才能取到这一集的流。
          source: episode.bvid.isEmpty
              ? 'https://www.bilibili.com/video/av${episode.aid}'
              : 'https://www.bilibili.com/video/${episode.bvid}',
          infoId: episode.bvid.isEmpty ? '${episode.aid}' : episode.bvid,
          page: 1,
          // 清单接口不返回 cid，预检解析过这一集，用它拿到的真实值补上，
          // 否则任务列表会显示「cid 0」。
          cid: preflight.cid > 0 ? preflight.cid : episode.cid,
          outputPath: finalPath,
          engine: engine,
          channel: 'manifest',
          // 地址直接复用预检结果：预检刚取过，没过期就不用再拉一遍。
          // 真过期了下载侧的 resolving 阶段会自己按 source 重取。
          videoUrl: video?.url ?? '',
          audioUrl: preflight.audio?.url ?? '',
          videoBackups: video?.backupUrls ?? const [],
          audioBackups: preflight.audio?.backupUrls ?? const [],
          videoQualityId: video?.id ?? 0,
          audioQualityId: preflight.audio?.id ?? 0,
          videoCodecs: video?.codecs ?? '',
          audioCodecs: preflight.audio?.codecs ?? '',
          createdAtMs: now.millisecondsSinceEpoch,
          batchId: batchId,
          seasonId: manifest.seasonId,
          seasonTitle: manifest.title,
          sectionId: section.id,
          sectionTitle: section.title,
          episodeIndex: episode.page,
        );
        taken.add(_pathKey(finalPath));
        tasks.insert(0, task);
        enqueuedIds.add(task.id);
        enqueued += 1;
      }
    }

    if (enqueued > 0) {
      // 这一批就是「最近一批」：任务页切进来时按它们的实际状态落栏。
      _recentEnqueued = enqueuedIds;
      _persistTasks();
      LogStore.instance.add(
        '任务',
        '批量入队：${manifest.title} —— 加入 $enqueued，跳过 $skipped，重命名 $renamed',
      );
      notifyListeners();
    }
    return DuplicateBatchOutcome(
      enqueued: enqueued,
      skipped: skipped,
      renamed: renamed,
    );
  }

  /// 批量把多 P 视频里选中的分 P 登记进队列。
  ///
  /// 与 [enqueueEpisodes] 走同一条路：**只登记、不解析** —— 档位写 `-1`
  /// （要这条轨道、档位待定），开跑时由 `_runTask` 的 resolving 阶段按
  /// `source` + `page` 逐 P 解析。cid 直接从 `view` 的 pages 里拿，不必再请求。
  ///
  /// 同名处理与查重规则跟 [enqueueEpisodes] 完全一致。
  DuplicateBatchOutcome enqueuePages({
    required ParsedMedia media,
    required Set<int> pages,
    required String engine,
  }) {
    if (pages.isEmpty) {
      return DuplicateBatchOutcome(enqueued: 0, skipped: 0, renamed: 0);
    }
    final dir = settings.downloadDir;
    final separator = Platform.pathSeparator;
    final source = media.info.bvid.isEmpty
        ? 'https://www.bilibili.com/video/av${media.info.aid}'
        : 'https://www.bilibili.com/video/${media.info.bvid}';
    final taken = <String>{
      for (final task in tasks) _pathKey(task.outputPath),
    };

    var enqueued = 0;
    var skipped = 0;
    var renamed = 0;
    final now = DateTime.now();
    final enqueuedIds = <String>{};

    for (final page in media.info.pages) {
      if (!pages.contains(page.page)) continue;
      // 文件名带上 P 序号：多 P 视频一集一个文件，重名会互相覆盖。
      final suffix = page.page > 1 ? ' P${page.page} ${page.part}' : '';
      final stem = sanitizeFileName('${media.info.title}$suffix');
      final target = _resolveDuplicatePath(
        dir: dir,
        stem: stem,
        extension: 'mp4',
        taken: taken,
      );
      if (target == null) {
        skipped += 1;
        continue;
      }
      if (target.renamed) renamed += 1;
      final candidate = target.candidate;
      final finalPath = target.path;

      final task = DownloadTask(
        id: '${now.microsecondsSinceEpoch}-${page.page}',
        title: candidate.split(separator).last,
        source: source,
        infoId: media.info.bvid.isEmpty ? '${media.info.aid}' : media.info.bvid,
        page: page.page,
        cid: page.cid,
        outputPath: finalPath,
        engine: engine,
        channel: media.channel,
        // -1 = 「要这条轨道、档位待定」：开跑时按设置里的首选档位取，
        // 该集缺这一档就取不超过它的最接近档。
        // 写 0 会被当成「不要这条轨道」，写死档位又会在缺档时报错。
        videoQualityId: -1,
        audioQualityId: -1,
        createdAtMs: now.millisecondsSinceEpoch,
      );
      taken.add(_pathKey(finalPath));
      tasks.insert(0, task);
      enqueuedIds.add(task.id);
      enqueued += 1;
    }

    if (enqueued > 0) {
      // 这一批就是「最近一批」：任务页切进来时按它们的实际状态落栏。
      _recentEnqueued = enqueuedIds;
      _persistTasks();
      LogStore.instance.add(
        '任务',
        '批量入队（多 P）：${media.info.title} —— 加入 $enqueued，'
        '跳过 $skipped，重命名 $renamed',
      );
      notifyListeners();
    }
    return DuplicateBatchOutcome(
      enqueued: enqueued,
      skipped: skipped,
      renamed: renamed,
    );
  }

  // ---------- 预检 ----------

  /// 预检调度：批次号、并发策略、结果缓存都在里面（见 core/preflight.dart）。
  late final PreflightRunner _preflight = PreflightRunner(
    resolve: _preflightOne,
    onChanged: notifyListeners,
  );

  bool get preflighting => _preflight.busy;

  bool isPreflighting(int page) => _preflight.isInFlight(page);

  PreflightResult preflightOf(int page) => _preflight.of(page);

  /// 仅测试用：直接写预检结果，免去真实请求。
  @visibleForTesting
  void seedPreflightForTest(Map<int, PreflightResult> results) =>
      _preflight.results.addAll(results);

  /// 换清单时清空，避免旧合集的结果串到新合集。
  void resetPreflight() => _preflight.reset();

  /// 对选中集做预检：只查选中的，取消勾选的会被清掉。
  Future<void> preflightEpisodes({
    required SeasonManifest manifest,
    required Set<int> pages,
  }) =>
      _preflight.run(
        episodes: manifest.allEpisodes,
        pages: pages,
        parallel: settings.parallelPreflight,
      );

  /// 查一集。异常在这里转成状态，不往外抛。
  Future<PreflightResult> _preflightOne(SeasonEpisode episode) async {
    try {
      final media = await parseService.parseTarget(
        episode.bvid.isEmpty
            ? 'https://www.bilibili.com/video/av${episode.aid}'
            : 'https://www.bilibili.com/video/${episode.bvid}',
        cookie: cookie,
        token: token ?? _emptyToken,
      );
      // 预检要的是这集最高可用档（用于缺档判定与标注），不是下载时按设置
      // 首选取流的那套规则，所以直接取第一条视频、最后一条音频。
      final video = media.videos.isEmpty ? null : media.videos.first;
      final audio = media.audios.isEmpty ? null : media.audios.last;
      if (video == null && audio == null) {
        return const PreflightResult(
          status: PreflightStatus.missingQuality,
          message: '这集没有可下载的流',
        );
      }
      // 「缺档」判定与单集解析同一套（[ParsedMedia.guestLimited]）：最高可用档
      // 低于你选的档就是缺档。标注只写「这集最高可用 X」——
      // 接口不区分「本来就没有这一档」和「有但你账号拿不到」，标注也就不该替它区分。
      if (media.guestLimited && video != null) {
        return PreflightResult(
          status: PreflightStatus.missingQuality,
          video: video,
          audio: audio,
          videoOptions: media.videos,
          cid: media.page.cid,
          message: l10n.tr('manifest.preflight.bestAvailable', {
            'quality': video.label,
          }),
        );
      }
      return PreflightResult(
        status: PreflightStatus.ok,
        video: video,
        audio: audio,
        videoOptions: media.videos,
        cid: media.page.cid,
      );
    } on BiliException catch (error) {
      // -352 是风控，不是「没有数据」：必须分开，否则会被误读成这集不可用。
      if (error.code == kRiskControlCode) {
        // 与下载阶段同一套处理：停手 + 提示，等用户点恢复。
        // halt 保留已查到的结果，只作废在跑的批次。
        _riskControlHit = true;
        _preflight.halt();
        notifyListeners();
        return PreflightResult(
          status: PreflightStatus.riskControl,
          message: error.message,
        );
      }
      return PreflightResult(
        status: PreflightStatus.unavailable,
        message: error.message,
      );
    } on Exception catch (error) {
      return PreflightResult(
        status: PreflightStatus.unavailable,
        message: '$error',
      );
    }
  }

  /// 有没有等着开跑的活。任务页的「全部开始」按这个决定能不能点。
  int get pendingCount =>
      tasks.where((task) => task.stage == TaskStage.pending).length;

  bool get hasPending => pendingCount > 0;

  void removeTask(String id) {
    tasks.removeWhere((task) => task.id == id);
    _persistTasks();
    notifyListeners();
  }

  /// 清理一个任务留下的文件（成品与全部分片），并把任务从列表移除。
  ///
  /// 只在用户点了「清理残留」时才删：失败任务的半截分片还能续传，
  /// 自动删掉等于把已经下好的部分扔掉。返回删掉的文件数。
  Future<int> cleanupTask(String id) async {
    final index = tasks.indexWhere((task) => task.id == id);
    if (index < 0) return 0;
    final task = tasks[index];
    if (_isRunning(task.stage)) return 0;
    final removed = await _removeTaskFiles(task);
    tasks.removeAt(index);
    await store.saveTasks(tasks);
    LogStore.instance.add('任务', '${task.title}：已清理 $removed 个残留文件');
    notifyListeners();
    return removed;
  }

  /// 正在跑的状态：这几种状态下任务握着取消句柄，文件也还在动。
  bool _isRunning(TaskStage stage) =>
      stage == TaskStage.downloading ||
      stage == TaskStage.muxing ||
      stage == TaskStage.resolving;

  /// 暂停：停掉当前这一轮，分片原样留着，继续时按断点接。
  ///
  /// 只在下载阶段可暂停。合并阶段没有检查点之外的落点，只能强制结束。
  void pauseTask(String id) {
    final index = tasks.indexWhere((task) => task.id == id);
    if (index < 0) return;
    final task = tasks[index];
    if (task.stage != TaskStage.downloading) return;
    final control = _controls[id];
    if (control == null) return;
    task.message = l10n.tr('msg.pausing');
    notifyListeners();
    control.pause();
  }

  /// 强制结束：停下当前这一轮，并把它留下的分片与半成品一起删掉。
  /// 删除交由下载/合并那一侧退出后再做，避免删着文件那边还在写。
  void stopTask(String id) {
    final index = tasks.indexWhere((task) => task.id == id);
    if (index < 0) return;
    final task = tasks[index];
    if (!_isRunning(task.stage)) return;
    task.message = l10n.tr('msg.stopping');
    notifyListeners();
    final control = _controls[id];
    if (control == null) {
      // 状态显示在跑、却已经没有活着的句柄：直接按结束处理。
      unawaited(_finishAborted(task, const TaskAborted(AbortReason.stop)));
      return;
    }
    control.stop();
  }

  /// 继续：保留分片与档位，回队列重新跑。地址带时效，沿途会重新解析一次。
  void resumeTask(String id) => retryTask(id, message: l10n.tr('msg.resuming'));

  /// 取消之后的收尾：暂停留分片，强制结束删干净。
  Future<void> _finishAborted(DownloadTask task, TaskAborted abort) async {
    if (abort.isPause) {
      task.stage = TaskStage.paused;
      task.message = l10n.tr('msg.paused');
      LogStore.instance.add('任务', '${task.title}：已暂停');
    } else {
      var removed = await removeArtifacts(task.videoPath);
      removed += await removeArtifacts(task.audioPath);
      removed += await removeArtifacts(task.outputPath);
      task.stage = TaskStage.stopped;
      task.message = l10n.tr('msg.stopped', {'count': '$removed'});
      LogStore.instance.add('任务', '${task.title}：强制结束，已删除 $removed 个残留文件');
    }
    _invalidateMergeReady();
    notifyListeners();
  }

  /// 重试保留原来的档位与编码：只清掉可能过期的 CDN 地址，重新解析时按原档位取，
  /// 用户不必回到解析页重选一次。分片留在盘上，「重试」与「继续」走的都是这条路。
  void retryTask(String id, {String? message}) {
    final task = tasks.firstWhere((item) => item.id == id);
    task.stage = TaskStage.pending;
    task.message = message ?? l10n.tr('msg.waitRetry');
    task.receivedBytes = 0;
    task.totalBytes = 0;
    task.merged = false;
    task.videoUrl = '';
    task.audioUrl = '';
    _persistTasks();
    notifyListeners();
    unawaited(pumpQueue());
  }

  /// 任务页等待栏单条卡片的「开始」：只启动这一条。
  ///
  /// 与顶部的「全部开始」（[pumpQueue] 不带过滤）分开 —— 等待栏排了好几条时，
  /// 用户常常只想先下其中一条。不是 `pending` 的直接忽略（界面上这个按钮也
  /// 只出现在 `pending` 态）。队列已在跑时这里等于没动，那条会被正在跑的
  /// 循环带走，不必也不能再起第二个泵。
  void startTask(String id) {
    final wanted = tasks.any(
      (item) => item.id == id && item.stage == TaskStage.pending,
    );
    if (!wanted) return;
    unawaited(pumpQueue(only: <String>{id}));
  }

  /// 跑队列：把 `pending` 的任务按并发上限一批批跑完。
  ///
  /// [only] 非空时只跑集合里的那些 —— 任务页等待栏单条卡片的「开始」用它，
  /// 点一条不会把等待栏里其他待下的一起带跑。省略即「全部开始」。
  Future<void> pumpQueue({Set<String>? only}) async {
    if (queueRunning) return;
    queueRunning = true;
    notifyListeners();
    final limit = settings.maxParallelTasks.clamp(1, 4);
    try {
      while (true) {
        // 风控：立刻停手，剩下的等用户点恢复。
        if (_riskControlHit) break;
        final batch = tasks
            .where(
              (task) =>
                  task.stage == TaskStage.pending &&
                  (only == null || only.contains(task.id)),
            )
            .take(limit)
            .toList();
        if (batch.isEmpty) break;
        await Future.wait(batch.map(_runTask));
        await store.saveTasks(tasks);
        notifyListeners();
      }
    } finally {
      queueRunning = false;
      notifyListeners();
    }
  }

  Future<void> _runTask(DownloadTask task) async {
    LogStore.instance.add(
      '任务',
      '开始：${task.title}｜引擎 ${task.engine}'
      '｜通道 ${task.channel.isEmpty ? '未记录' : task.channel}',
    );
    final control = AbortControl();
    _controls[task.id] = control;
    try {
      if (task.engine != 'dart') {
        throw BiliException(l10n.tr('err.engineMissing'));
      }
      final dir = Directory(settings.downloadDir);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      // 合集任务的产物与分片都放在合集子目录（outputPath 的父目录）里；
      // 不建这个子目录的话分片会散落在下载根目录，跟产物对不上。
      final outDir = Directory(File(task.outputPath).parent.path);
      if (!outDir.existsSync()) {
        await outDir.create(recursive: true);
      }
      if ((task.videoQualityId != 0 && task.videoUrl.isEmpty) ||
          (task.audioQualityId != 0 && task.audioUrl.isEmpty)) {
        task.stage = TaskStage.resolving;
        task.message = l10n.tr('msg.urlExpired');
        notifyListeners();
        await _refreshTaskUrls(task);
      }

      // 档位 0 表示用户在界面上取消了这条轨道，单轨任务不做合并。
      final wantsVideo = task.videoQualityId != 0;
      final wantsAudio = task.audioQualityId != 0;
      if (!wantsVideo && !wantsAudio) {
        throw BiliException(l10n.tr('err.noTrack'));
      }

      final base = sanitizeFileName(task.title);
      final separator = Platform.pathSeparator;
      task.videoPath = '${outDir.path}$separator$base.video.m4s';
      task.audioPath = '${outDir.path}$separator$base.audio.m4s';
      task.outputPath = '${outDir.path}$separator$base.${wantsVideo ? 'mp4' : 'm4a'}';

      task.stage = TaskStage.downloading;
      // 已经落盘的流不再重下：暂停后继续、合并失败后重试都靠这一条，
      // 否则「继续」会把已经下好的另一半从头再拉一遍。
      if (wantsVideo) {
        if (await _streamReady(task.videoPath)) {
          LogStore.instance.add('任务', '${task.title}：视频流已在本地，跳过下载');
        } else {
          task.message = l10n.tr('msg.downloadVideo');
          task.receivedBytes = 0;
          task.totalBytes = 0;
          notifyListeners();
          await downloader.download(
            url: task.videoUrl,
            backups: task.videoBackups,
            targetPath: task.videoPath,
            control: control,
            parts: settings.partsPerFile,
            onProgress: (received, total) => _pushProgress(task, received, total),
          );
        }
      }

      if (wantsAudio) {
        if (await _streamReady(task.audioPath)) {
          LogStore.instance.add('任务', '${task.title}：音频流已在本地，跳过下载');
        } else {
          task.message = l10n.tr('msg.downloadAudio');
          task.receivedBytes = 0;
          task.totalBytes = 0;
          notifyListeners();
          await downloader.download(
            url: task.audioUrl,
            backups: task.audioBackups,
            targetPath: task.audioPath,
            control: control,
            parts: settings.partsPerFile,
            onProgress: (received, total) => _pushProgress(task, received, total),
          );
        }
      }

      if (wantsVideo && wantsAudio) {
        if (!hasUsableFile(task.videoPath)) {
          throw BiliException(l10n.tr('err.emptyVideo'));
        }
        if (!hasUsableFile(task.audioPath)) {
          throw BiliException(l10n.tr('err.emptyAudio'));
        }
        await _muxTask(task, control: control);
        return;
      }

      // 只下了一条轨道：没有可合并的东西，分片直接改名成产物。
      final source = wantsVideo ? task.videoPath : task.audioPath;
      if (!hasUsableFile(source)) {
        throw BiliException(wantsVideo ? l10n.tr('err.emptyVideo') : l10n.tr('err.emptyAudio'));
      }
      await _finalizeSingle(task, source);
    } on TaskAborted catch (abort) {
      await _finishAborted(task, abort);
    } on Exception catch (error) {
      final code = error is BiliException ? error.code : null;
      if (code == kRiskControlCode) {
        // 风控不是失败：分片与档位都留着，暂停这一集等用户手动恢复。
        task.stage = TaskStage.paused;
        task.message = l10n.tr('msg.riskControl');
        _riskPaused.add(task.id);
        _riskControlHit = true;
        LogStore.instance.add('任务', '风控暂停：${task.title}：$error');
        notifyListeners();
      } else {
        task.stage = TaskStage.failed;
        task.message = '$error';
        // 下载途中撞到凭据失效（多半是重解析地址那一步）也提示一句，
        // 不然只看到任务失败，不知道是登录过期还是片源没了。
        final expired = authNotice(error);
        if (expired != null) notice = expired;
        LogStore.instance.add('任务', '失败：${task.title}：$error');
        notifyListeners();
      }
    } finally {
      _controls.remove(task.id);
      _progressPushedAt.remove(task.id);
      // 分片状态定型，让卡片重新判断「重试合并」。
      _invalidateMergeReady();
      await store.saveTasks(tasks);
      notifyListeners();
    }
  }

  /// 后台落盘任务列表：不阻塞调用点，失败写日志。
  ///
  /// 既不静默吞掉错误（写进 [LogStore]），也不产生未处理异步异常（错误在这里被收掉）。
  /// 需要确认落盘结果的调用点仍然用 `await store.saveTasks(...)`，不走这里。
  void _persistTasks() {
    unawaited(
      store.saveTasks(tasks).catchError((Object error, StackTrace stack) {
        LogStore.instance.add('存储', '保存任务失败：${_saveFailureText(error)}');
        // 堆栈标成 detail：只在详细日志打开时才记录，避免默认日志沾上构建期路径。
        LogStore.instance.add('存储', '保存任务失败堆栈：$stack', detail: true);
      }),
    );
  }

  /// 把保存失败的错误压成一行日志文本，**不含用户数据目录的绝对路径**。
  ///
  /// ⚠️ 不要直接写 `$error`：`FileSystemException.toString()` 会把 `path` 拼进去，
  /// 那是用户数据目录的绝对路径。这里只取异常类型、简短说明与系统错误码。
  /// 其它异常类型一律**只记类型** —— 本项目自己的异常消息里也会拼路径
  /// （如「文件不存在：/…」）。
  /// [LogStore.add] 内部的 `mask()` 只挡凭据、不挡路径，纵深保护不能代替调用点做最小化。
  String _saveFailureText(Object error) {
    final parts = <String>[error.runtimeType.toString()];
    if (error is FileSystemException) {
      // dart:io 抛 FileSystemException 时 message 是固定文案（路径单独放在 path 字段），
      // osError.message 是系统文案，两者都不含路径。
      if (error.message.isNotEmpty) parts.add(error.message);
      final os = error.osError;
      if (os != null) parts.add('osError=${os.errorCode} ${os.message}');
    }
    final text = parts.join(' | ');
    // 兜底：无论异常从哪来，都不让数据目录前缀出现在日志里。
    final root = store.root.path;
    return root.isEmpty ? text : text.replaceAll(root, '<数据目录>');
  }

  /// 进度回调一秒能来几十次，节流到 100ms 一次再通知界面。
  /// 之前这里只写字段不通知，界面上进度就一直是 0，直到换阶段才跳一下。
  ///
  /// 时间戳按任务分别记：共用一个的话，紧跟在前一个任务之后的回调会被吞掉。
  static const int _progressMinGapMs = 100;
  final Map<String, DateTime> _progressPushedAt = <String, DateTime>{};

  void _pushProgress(DownloadTask task, int received, int total) {
    task.receivedBytes = received;
    task.totalBytes = total;
    final now = DateTime.now();
    final last = _progressPushedAt[task.id];
    if (last != null && now.difference(last).inMilliseconds < _progressMinGapMs) {
      return;
    }
    _progressPushedAt[task.id] = now;
    _notifyProgress();
  }

  /// 仅测试用：从下载/合并真正走的那条入口发一次进度通知（含节流），
  /// 用来钉住 [stableView] 确实吞掉了这一路。
  @visibleForTesting
  void pushProgressForTest(DownloadTask task, int received, int total) =>
      _pushProgress(task, received, total);

  /// 分片是否都还在 —— 任务卡片据此决定「重试合并」按钮显不显示。
  ///
  /// 按任务缓存结果：底层是同步 stat，而卡片每次 build 都会问一次，
  /// 下载期通知密度高，读盘会直接压在主 isolate 上。
  final Map<String, bool> _mergeReady = <String, bool>{};

  bool canRetryMerge(DownloadTask task) {
    if (task.singleTrack || task.audioPath.isEmpty) return false;
    final cached = _mergeReady[task.id];
    if (cached != null) return cached;
    final ready = hasUsableFile(task.videoPath) && hasUsableFile(task.audioPath);
    _mergeReady[task.id] = ready;
    return ready;
  }

  /// 分片可能变化后调用，下次读取重新读盘。
  /// 清整表而不是按 id 删：调用点少且不在热路径上，漏一个 id 会让按钮该出不出。
  void _invalidateMergeReady() => _mergeReady.clear();

  /// 合并成功后原始分片就没用了，顺手清掉，别让下载目录越堆越大。
  Future<int> _removeSources(DownloadTask task) async {
    var removed = await removeArtifacts(task.videoPath);
    removed += await removeArtifacts(task.audioPath);
    if (removed > 0) {
      LogStore.instance.add('合并', '${task.title}：已清理 $removed 个分片');
    }
    _invalidateMergeReady();
    return removed;
  }

  /// 流已经完整落盘：下载成功后分片会改名成 `.m4s`，看到它且非空就当已就绪。
  /// 单连接与分段两条路径都在确认收满字节之后才改名，所以这不算「猜」。
  Future<bool> _streamReady(String path) async {
    if (path.isEmpty) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    return await file.length() > 0;
  }

  /// 单轨任务的落定：把分片改名成最终产物，不给用户留一个 .m4s。
  /// 只下视频得到无声 mp4，只下音频得到 m4a，两者都不合并。
  Future<void> _finalizeSingle(DownloadTask task, String sourcePath) async {
    final target = File(task.outputPath);
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    var path = target.path;
    try {
      path = (await File(sourcePath).rename(target.path)).path;
    } on FileSystemException {
      // 跨卷时不支持改名，退回复制。
      await File(sourcePath).copy(target.path);
      await File(sourcePath).delete();
    }
    task.merged = false;
    task.stage = TaskStage.done;
    task.message = l10n.tr('msg.singleTrackDone', {'path': path});
    LogStore.instance.add('任务', '${task.title}：单轨完成 $path');
  }

  /// 合并音视频。ffmpeg 在就用 ffmpeg，没有就走内置分片合并；
  /// 两条路都失败时保留分片并把原因写进任务消息，界面可以单独重试合并。
  /// 合并期间「强制结束」会掐掉正在跑的 ffmpeg；取消异常交给调用方收尾。
  Future<void> _muxTask(DownloadTask task, {AbortControl? control}) async {
    task.stage = TaskStage.muxing;
    task.message = l10n.tr('msg.muxing');
    notifyListeners();
    try {
      final outcome = await Muxer.merge(
        ffmpegPath: ffmpegPath ?? '',
        preferFfmpeg: settings.preferFfmpegMux,
        videoPath: task.videoPath,
        audioPath: task.audioPath,
        outputPath: task.outputPath,
        control: control,
        // 与下载进度共用节流器。⚠️ 只能节流这里的通知，不能降低 onProgress
        // 的调用次数 —— 内置合并的取消检查点就挂在它里面。
        onProgress: (written, total) => _pushProgress(task, written, total),
      );
      task.merged = true;
      task.stage = TaskStage.done;
      final removed = await _removeSources(task);
      task.message = l10n.tr(
            'msg.done',
            {'engine': outcome.engineLabel, 'path': task.outputPath},
          ) +
          (removed > 0
              ? l10n.tr('msg.fragmentsRemoved', {'count': '$removed'})
              : '');
    } on TaskAborted {
      rethrow;
    } on Exception catch (error) {
      task.merged = false;
      task.stage = TaskStage.done;
      task.message = l10n.tr('msg.muxFailed', {'error': '$error'});
      LogStore.instance.add('合并', '${task.title}：两条路径都失败，保留分片：$error');
    }
    _progressPushedAt.remove(task.id);
    notifyListeners();
  }

  /// 只重跑合并，不重新下载。
  Future<void> retryMerge(String id) async {
    final task = tasks.firstWhere((item) => item.id == id);
    if (_isRunning(task.stage)) return;
    if (task.videoQualityId == 0 || task.audioQualityId == 0) {
      task.message = l10n.tr('msg.singleTrackNoMux');
      notifyListeners();
      return;
    }
    if (!hasUsableFile(task.videoPath) || !hasUsableFile(task.audioPath)) {
      task.message = l10n.tr('msg.missingFragments');
      notifyListeners();
      return;
    }
    final control = AbortControl();
    _controls[task.id] = control;
    try {
      await _muxTask(task, control: control);
    } on TaskAborted catch (abort) {
      await _finishAborted(task, abort);
    } finally {
      _controls.remove(task.id);
    }
    await store.saveTasks(tasks);
  }

  /// 断点续传前先补地址：旧任务里的 CDN 地址可能已经过期。
  ///
  /// 取流严格按任务记录的档位与编码（`videoQualityId` / `audioQualityId`）：找不到同一个
  /// 档位就报错，不静默换成别的档位——否则用户选了 8K、重试后拿到更低的档位也不会发现。
  /// 档位为 -1 的是档位待定（老任务或批量入队），按设置里的首选档位取，缺档取
  /// 不超过它的最接近档；取完把实际用到的档位补写回任务。
  Future<void> _refreshTaskUrls(DownloadTask task) async {
    LogStore.instance.add('任务', '${task.title}：地址已失效，按原档位重新解析');
    final media = await parseService.parseTarget(
      task.source,
      cookie: cookie,
      token: token ?? _emptyToken,
      pageOverride: task.page,
    );

    if (task.videoQualityId != 0) {
      final video = resolveRecordedStream(
        media.videos,
        task.videoQualityId,
        task.videoCodecs,
        fallbackFirst: true,
        preferred: settings.preferredQuality,
      );
      if (video == null) {
        throw BiliException(task.videoQualityId > 0
            ? l10n.tr('msg.videoQualityGone', {
                'quality': qualityLabel(task.videoQualityId, l10n),
              })
            : l10n.tr('msg.noVideoStream'));
      }
      task.videoUrl = video.url;
      task.videoBackups = video.backupUrls;
      task.videoQualityId = video.id;
      task.videoCodecs = video.codecs;
    } else {
      task.videoUrl = '';
      task.videoBackups = const [];
    }

    if (task.audioQualityId != 0) {
      final audio = resolveRecordedStream(
        media.audios,
        task.audioQualityId,
        task.audioCodecs,
        fallbackFirst: false,
        preferred: settings.preferredAudio,
      );
      if (audio == null) {
        if (task.audioQualityId > 0) {
          throw BiliException(
            l10n.tr('msg.audioQualityGone', {
              'quality': audioLabel(task.audioQualityId, l10n),
            }),
          );
        }
        // 老任务本来要音频，这次解析没有独立音频流：改成只下视频。
        task.audioUrl = '';
        task.audioBackups = const [];
        task.audioQualityId = 0;
      } else {
        task.audioUrl = audio.url;
        task.audioBackups = audio.backupUrls;
        task.audioQualityId = audio.id;
        task.audioCodecs = audio.codecs;
      }
    } else {
      task.audioUrl = '';
      task.audioBackups = const [];
    }

    task.channel = media.channel;
  }

  @override
  void dispose() {
    _authTimer?.cancel();
    // 退出前把还在跑的任务掐断，别让它们在进程收尾时继续写文件。
    for (final control in _controls.values) {
      control.stop();
    }
    _controls.clear();
    api.close();
    super.dispose();
  }
}

/// 从 [AppState] 上切出来的一小块可监听视图。
///
/// 两种过滤可叠加，都在**通知到达时**生效，不改变 AppState 自己的通知时机：
/// - [ignoreProgress]：吞掉「只改了任务字节进度」的通知；
/// - [snapshot]：快照用记录类型（按值比较），只有真的变了才往下传。
class _StateView extends ChangeNotifier {
  _StateView(this._state, {this.ignoreProgress = false, this.snapshot})
      : _last = snapshot?.call() {
    _state.addListener(_onChanged);
  }

  final AppState _state;
  final bool ignoreProgress;
  final Object? Function()? snapshot;
  Object? _last;

  void _onChanged() {
    if (ignoreProgress && _state._progressOnly) return;
    final read = snapshot;
    if (read != null) {
      final value = read();
      if (value == _last) return;
      _last = value;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _state.removeListener(_onChanged);
    super.dispose();
  }
}
