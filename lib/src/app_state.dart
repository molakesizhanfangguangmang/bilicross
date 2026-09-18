import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'core/abort.dart';
import 'core/bili_api.dart';
import 'core/downloader.dart';
import 'core/log_store.dart';
import 'core/models.dart';
import 'core/muxer.dart';
import 'core/parser.dart';
import 'core/signing.dart';
import 'core/store.dart';
import 'i18n/app_localizations.dart';
import 'i18n/app_localizations_zh.dart';

class AppState extends ChangeNotifier {
  AppState._(this.store, this.settings, this.cookie, this.token, this.tasks) {
    api = _buildApi();
    parseService = ParseService(api: api, settings: settings);
    downloader = StreamDownloader(
      userAgent: settings.userAgent,
      proxy: settings.proxy,
    );
  }

  static Future<AppState> load() async {
    final store = await Store.open();
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
  String notice = '';
  bool busy = false;
  bool queueRunning = false;
  String? ffmpegPath;

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

  // ---------- 设置 ----------

  Future<void> saveSettings() async {
    await store.saveSettings(settings);
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

  Future<void> parseAddress(String input) async {
    addressInput = input;
    busy = true;
    parsed = null;
    notice = '';
    LogStore.instance.add('解析', '地址：$input');
    notifyListeners();
    try {
      parsed = await parseService.parseTarget(
        input,
        cookie: cookie,
        token: token ?? _emptyToken,
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

  void enqueue({
    required MediaStream? video,
    required MediaStream? audio,
    required String engine,
  }) {
    final media = parsed;
    if (media == null) return;
    if (video == null && audio == null) return;
    final dir = settings.downloadDir;
    final name = sanitizeFileName(
      '${media.info.title}${media.page.page > 1 ? ' P${media.page.page} ${media.page.part}' : ''}',
    );
    final task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: name,
      source: addressInput,
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
    unawaited(store.saveTasks(tasks));
    LogStore.instance.add('任务', '入队：${task.title}（等待开始）');
    notifyListeners();
  }

  /// 有没有等着开跑的活。任务页的「开始任务」按这个决定能不能点。
  int get pendingCount =>
      tasks.where((task) => task.stage == TaskStage.pending).length;

  bool get hasPending => pendingCount > 0;

  void removeTask(String id) {
    tasks.removeWhere((task) => task.id == id);
    unawaited(store.saveTasks(tasks));
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
    var removed = await removeArtifacts(task.videoPath);
    removed += await removeArtifacts(task.audioPath);
    if (!task.merged) {
      removed += await removeArtifacts(task.outputPath);
    }
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
    unawaited(store.saveTasks(tasks));
    notifyListeners();
    unawaited(pumpQueue());
  }

  Future<void> pumpQueue() async {
    if (queueRunning) return;
    queueRunning = true;
    notifyListeners();
    final limit = settings.maxParallelTasks.clamp(1, 4);
    try {
      while (true) {
        final batch = tasks.where((task) => task.stage == TaskStage.pending).take(limit).toList();
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
      task.videoPath = '${dir.path}$separator$base.video.m4s';
      task.audioPath = '${dir.path}$separator$base.audio.m4s';
      task.outputPath = '${dir.path}$separator$base.${wantsVideo ? 'mp4' : 'm4a'}';

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
      task.stage = TaskStage.failed;
      task.message = '$error';
      // 下载途中撞到凭据失效（多半是重解析地址那一步）也提示一句，
      // 不然只看到任务失败，不知道是登录过期还是片源没了。
      final expired = authNotice(error);
      if (expired != null) notice = expired;
      LogStore.instance.add('任务', '失败：${task.title}：$error');
      notifyListeners();
    } finally {
      _controls.remove(task.id);
      await store.saveTasks(tasks);
      notifyListeners();
    }
  }

  /// 进度回调一秒能来几十次，节流到 100ms 一次再通知界面。
  /// 之前这里只写字段不通知，界面上进度就一直是 0，直到换阶段才跳一下。
  DateTime _progressPushedAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _pushProgress(DownloadTask task, int received, int total) {
    task.receivedBytes = received;
    task.totalBytes = total;
    final now = DateTime.now();
    if (now.difference(_progressPushedAt).inMilliseconds < 100) return;
    _progressPushedAt = now;
    notifyListeners();
  }

  /// 合并成功后原始分片就没用了，顺手清掉，别让下载目录越堆越大。
  Future<int> _removeSources(DownloadTask task) async {
    var removed = await removeArtifacts(task.videoPath);
    removed += await removeArtifacts(task.audioPath);
    if (removed > 0) {
      LogStore.instance.add('合并', '${task.title}：已清理 $removed 个分片');
    }
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
        onProgress: (written, total) {
          task.receivedBytes = written;
          task.totalBytes = total;
          notifyListeners();
        },
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
  /// 档位为 -1 的是没有记录的老任务，按老行为取（视频第一条、音频最后一条），
  /// 取完把实际用到的档位补写回任务。
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
