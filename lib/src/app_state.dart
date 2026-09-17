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
      } else if (task.stage == TaskStage.paused) {
        // 暂停的任务留在暂停态：分片还在，等着用户点「继续」。
        // 地址同样过期，继续时会重新解析，分片照样按断点接。
        task.message = '上次退出时暂停，点「继续」从断点接';
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
    LogStore.instance.add(
      '账号',
      'WEB Cookie 已写入：SESSDATA ${parsedCookie.sessData.length} 字符'
      '｜bili_jct ${parsedCookie.biliJct.isEmpty ? '无' : '有'}'
      '｜DedeUserID ${parsedCookie.dedeUserId.isEmpty ? '无' : '有'}',
    );
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
    LogStore.instance.add('账号', 'WEB Cookie 已清除');
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
    LogStore.instance.add('解析', '地址：$input');
    notifyListeners();
    try {
      parsed = await parseService.parseTarget(
        input,
        cookie: cookie,
        token: token ?? _emptyToken,
      );
      notice = parsed!.guestLimited ? '当前未登录或无可用 Token，清晰度受限' : '';
      if (parsed!.guestLimited) {
        LogStore.instance.add('解析', '清晰度受限：实际最高档位低于请求档位');
      }
    } on Exception catch (error) {
      notice = '$error';
      LogStore.instance.add('解析', '解析失败：$error');
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
    notifyListeners();
  }

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
    task.message = '正在暂停…';
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
    task.message = '正在强制结束…';
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
  void resumeTask(String id) => retryTask(id, message: '继续下载（从断点接）');

  /// 取消之后的收尾：暂停留分片，强制结束删干净。
  Future<void> _finishAborted(DownloadTask task, TaskAborted abort) async {
    if (abort.isPause) {
      task.stage = TaskStage.paused;
      task.message = '已暂停，分片已保留，点「继续」从断点接';
      LogStore.instance.add('任务', '${task.title}：已暂停');
    } else {
      var removed = await removeArtifacts(task.videoPath);
      removed += await removeArtifacts(task.audioPath);
      removed += await removeArtifacts(task.outputPath);
      task.stage = TaskStage.stopped;
      task.message = '已强制结束，已删除 $removed 个残留文件';
      LogStore.instance.add('任务', '${task.title}：强制结束，已删除 $removed 个残留文件');
    }
    notifyListeners();
  }

  /// 重试保留原来的档位与编码：只清掉可能过期的 CDN 地址，重新解析时按原档位取，
  /// 用户不必回到解析页重选一次。分片留在盘上，「重试」与「继续」走的都是这条路。
  void retryTask(String id, {String message = '等待重试'}) {
    final task = tasks.firstWhere((item) => item.id == id);
    task.stage = TaskStage.pending;
    task.message = message;
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
        throw BiliException('BBDownNext 兼容引擎尚未接入，请改用 Dart 内置引擎');
      }
      final dir = Directory(settings.downloadDir);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      if ((task.videoQualityId != 0 && task.videoUrl.isEmpty) ||
          (task.audioQualityId != 0 && task.audioUrl.isEmpty)) {
        task.stage = TaskStage.resolving;
        task.message = '地址已失效，按原档位重新解析';
        notifyListeners();
        await _refreshTaskUrls(task);
      }

      // 档位 0 表示用户在界面上取消了这条轨道，单轨任务不做合并。
      final wantsVideo = task.videoQualityId != 0;
      final wantsAudio = task.audioQualityId != 0;
      if (!wantsVideo && !wantsAudio) {
        throw BiliException('任务没有选择任何轨道');
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
          task.message = '下载视频流';
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
          task.message = '下载音频流';
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
          throw BiliException('视频分片为空');
        }
        if (!hasUsableFile(task.audioPath)) {
          throw BiliException('音频分片为空');
        }
        await _muxTask(task, control: control);
        return;
      }

      // 只下了一条轨道：没有可合并的东西，分片直接改名成产物。
      final source = wantsVideo ? task.videoPath : task.audioPath;
      if (!hasUsableFile(source)) {
        throw BiliException(wantsVideo ? '视频分片为空' : '音频分片为空');
      }
      await _finalizeSingle(task, source);
    } on TaskAborted catch (abort) {
      await _finishAborted(task, abort);
    } on Exception catch (error) {
      task.stage = TaskStage.failed;
      task.message = '$error';
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
    task.message = '完成（单轨）：$path';
    LogStore.instance.add('任务', '${task.title}：单轨完成 $path');
  }

  /// 合并音视频。ffmpeg 在就用 ffmpeg，没有就走内置分片合并；
  /// 两条路都失败时保留分片并把原因写进任务消息，界面可以单独重试合并。
  /// 合并期间「强制结束」会掐掉正在跑的 ffmpeg；取消异常交给调用方收尾。
  Future<void> _muxTask(DownloadTask task, {AbortControl? control}) async {
    task.stage = TaskStage.muxing;
    task.message = '合并音视频';
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
      task.message = '完成（${outcome.engineLabel}）：${task.outputPath}'
          '${removed > 0 ? '（已清理 $removed 个分片）' : ''}';
    } on TaskAborted {
      rethrow;
    } on Exception catch (error) {
      task.merged = false;
      task.stage = TaskStage.done;
      task.message = '合并失败，两个分片已保留，可稍后重试：$error';
      LogStore.instance.add('合并', '${task.title}：两条路径都失败，保留分片：$error');
    }
    notifyListeners();
  }

  /// 只重跑合并，不重新下载。
  Future<void> retryMerge(String id) async {
    final task = tasks.firstWhere((item) => item.id == id);
    if (_isRunning(task.stage)) return;
    if (task.videoQualityId == 0 || task.audioQualityId == 0) {
      task.message = '该任务只下了一条轨道，没有可合并的分片';
      notifyListeners();
      return;
    }
    if (!hasUsableFile(task.videoPath) || !hasUsableFile(task.audioPath)) {
      task.message = '缺少视频或音频分片，请重新下载';
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
            ? '原选择的视频档位（${qualityLabel(task.videoQualityId)}）本次解析没有返回'
            : '本次解析没有返回任何视频流');
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
            '原选择的音频档位（${audioLabel(task.audioQualityId)}）本次解析没有返回',
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
