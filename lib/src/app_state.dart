import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'core/bili_api.dart';
import 'core/downloader.dart';
import 'core/models.dart';
import 'core/muxer.dart';
import 'core/parser.dart';
import 'core/signing.dart';
import 'core/store.dart';

class AppState extends ChangeNotifier {
  AppState._(this.store, this.settings, this.cookie, this.token, this.tasks) {
    api = _buildApi();
    parseService = ParseService(api: api, settings: settings);
    downloader = StreamDownloader(client: api.client, userAgent: settings.userAgent);
  }

  static Future<AppState> load() async {
    final store = await Store.open();
    final settings = await store.loadSettings();
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
        task.message = '上次退出时中断，等待继续';
        // CDN 地址带时效，续传前必须重新解析，不能沿用上次的地址。
        task.videoUrl = '';
        task.audioUrl = '';
      }
    }
    return AppState._(store, settings, credentials.cookie, credentials.token, tasks);
  }

  final Store store;
  AppSettings settings;
  WebCookie cookie;
  AppToken? token;
  final List<DownloadTask> tasks;

  late BiliApi api;
  late ParseService parseService;
  late StreamDownloader downloader;

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
    downloader = StreamDownloader(client: api.client, userAgent: settings.userAgent);
  }

  // ---------- 设置 ----------

  Future<void> saveSettings() async {
    await store.saveSettings(settings);
    await _rebuildApi();
    await refreshFfmpeg();
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
      throw BiliException('没有从内容里提取到 SESSDATA 字段');
    }
    cookie = parsedCookie;
    await store.saveCredentials(CredentialBundle(cookie: cookie, token: token));
    notice = parsedCookie.isComplete
        ? '已写入 WEB Cookie'
        : '已写入 WEB Cookie，但缺少 ${parsedCookie.biliJct.isEmpty ? 'bili_jct ' : ''}${parsedCookie.dedeUserId.isEmpty ? 'DedeUserID' : ''}';
    notifyListeners();
    await refreshAccount();
  }

  Future<void> clearCookie() async {
    cookie = const WebCookie.empty();
    await store.saveCredentials(CredentialBundle(cookie: cookie, token: token));
    account = const AccountState(loggedIn: false, message: '已清除 WEB Cookie');
    notifyListeners();
  }

  Future<void> refreshAccount() async {
    if (cookie.isEmpty) {
      account = const AccountState(loggedIn: false, message: '未配置 WEB Cookie');
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      account = await api.fetchAccount(cookie.raw);
    } on Exception catch (error) {
      account = AccountState(loggedIn: false, message: '$error');
    }
    busy = false;
    notifyListeners();
  }

  // ---------- APP Token ----------

  Future<void> startAppAuth() async {
    if (cookie.isEmpty) {
      throw BiliException('请先写入 WEB Cookie');
    }
    pendingAuth = await api.requestAppAuthCode();
    authStatus = '等待在浏览器中确认授权';
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
      authStatus = '授权超时，请重新发起';
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
          authStatus = 'APP Token 已获取';
          notifyListeners();
        case AppPollStatus.expired:
        case AppPollStatus.failed:
          _authTimer?.cancel();
          _authTimer = null;
          authStatus = outcome.message;
          notifyListeners();
      }
    } on Exception catch (error) {
      authStatus = '轮询失败：$error';
      notifyListeners();
    }
  }

  // ---------- 解析 ----------

  Future<void> parseAddress(String input) async {
    addressInput = input;
    busy = true;
    parsed = null;
    notice = '';
    notifyListeners();
    try {
      parsed = await parseService.parseTarget(
        input,
        cookie: cookie,
        token: token ?? _emptyToken,
      );
      notice = parsed!.guestLimited ? '当前未登录或无可用 Token，清晰度受限' : '';
    } on Exception catch (error) {
      notice = '$error';
    }
    busy = false;
    notifyListeners();
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
    required MediaStream video,
    required MediaStream audio,
    required String engine,
  }) {
    final media = parsed;
    if (media == null) return;
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
      outputPath: '$dir${Platform.pathSeparator}$name.mp4',
      engine: engine,
      channel: media.channel,
      videoUrl: video.url,
      audioUrl: audio.url,
      videoBackups: video.backupUrls,
      audioBackups: audio.backupUrls,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    tasks.insert(0, task);
    unawaited(store.saveTasks(tasks));
    notifyListeners();
  }

  void removeTask(String id) {
    tasks.removeWhere((task) => task.id == id);
    unawaited(store.saveTasks(tasks));
    notifyListeners();
  }

  void retryTask(String id) {
    final task = tasks.firstWhere((item) => item.id == id);
    task.stage = TaskStage.pending;
    task.message = '等待重试';
    task.receivedBytes = 0;
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
    try {
      if (task.engine != 'dart') {
        throw BiliException('BBDownNext 兼容引擎尚未接入，请改用 Dart 内置引擎');
      }
      final dir = Directory(settings.downloadDir);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      if (task.videoUrl.isEmpty) {
        task.stage = TaskStage.resolving;
        task.message = '地址已失效，重新解析';
        notifyListeners();
        await _refreshTaskUrls(task);
      }
      task.stage = TaskStage.downloading;
      task.message = '下载视频流';
      notifyListeners();

      final base = sanitizeFileName(task.title);
      task.videoPath = '${dir.path}${Platform.pathSeparator}$base.video.m4s';
      task.audioPath = '${dir.path}${Platform.pathSeparator}$base.audio.m4s';
      task.outputPath = '${dir.path}${Platform.pathSeparator}$base.mp4';

      await downloader.download(
        url: task.videoUrl,
        backups: task.videoBackups,
        targetPath: task.videoPath,
        onProgress: (received, total) {
          task.receivedBytes = received;
          task.totalBytes = total;
        },
        isCancelled: () => task.stage == TaskStage.failed,
      );

      if (task.audioUrl.isNotEmpty) {
        task.message = '下载音频流';
        task.receivedBytes = 0;
        notifyListeners();
        await downloader.download(
          url: task.audioUrl,
          backups: task.audioBackups,
          targetPath: task.audioPath,
          onProgress: (received, total) {
            task.receivedBytes = received;
            task.totalBytes = total;
          },
          isCancelled: () => task.stage == TaskStage.failed,
        );
      }

      if (!hasUsableFile(task.videoPath)) {
        throw BiliException('视频分片为空');
      }

      if (task.audioUrl.isEmpty || !hasUsableFile(task.audioPath)) {
        task.merged = false;
        task.stage = TaskStage.done;
        task.message = '已下载单文件流，未做合并';
        notifyListeners();
        return;
      }

      task.stage = TaskStage.muxing;
      task.message = '合并音视频';
      notifyListeners();
      final binary = await Muxer.locate(settings.ffmpegPath);
      if (binary == null) {
        task.stage = TaskStage.done;
        task.merged = false;
        task.message = '未找到 ffmpeg，音视频分片已保留，可在设置里指定后重试合并';
        notifyListeners();
        return;
      }
      await Muxer.remux(
        ffmpeg: binary,
        videoPath: task.videoPath,
        audioPath: task.audioPath,
        outputPath: task.outputPath,
      );
      task.merged = true;
      task.stage = TaskStage.done;
      task.message = '完成：${task.outputPath}';
      notifyListeners();
    } on Exception catch (error) {
      task.stage = TaskStage.failed;
      task.message = '$error';
      notifyListeners();
    } finally {
      await store.saveTasks(tasks);
      notifyListeners();
    }
  }

  /// 断点续传前先补地址：旧任务里的 CDN 地址可能已经过期。
  Future<void> _refreshTaskUrls(DownloadTask task) async {
    final media = await parseService.parseTarget(
      task.source,
      cookie: cookie,
      token: token ?? _emptyToken,
      pageOverride: task.page,
    );
    final video = media.videos.first;
    final audio = media.audios.isEmpty ? null : media.audios.last;
    task.videoUrl = video.url;
    task.videoBackups = video.backupUrls;
    task.audioUrl = audio?.url ?? '';
    task.audioBackups = audio?.backupUrls ?? const [];
    task.channel = media.channel;
  }

  @override
  void dispose() {
    _authTimer?.cancel();
    api.close();
    super.dispose();
  }
}
