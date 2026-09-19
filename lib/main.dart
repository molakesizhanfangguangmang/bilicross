import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_state.dart';
import 'src/core/distribution.dart';
import 'src/core/log_store.dart';
import 'src/core/splash_config.dart';
import 'src/core/startup_check.dart';
import 'src/core/update_check.dart';
import 'src/i18n/app_localizations.dart';
import 'src/i18n/app_localizations_zh.dart';
import 'src/platform/windows/desktop_shell.dart';
import 'src/ui/about_dialog.dart';
import 'src/ui/account_page.dart';
import 'src/ui/download_page.dart';
import 'src/ui/settings_page.dart';
import 'src/ui/splash_screen.dart';
import 'src/ui/startup_failure_page.dart';
import 'src/ui/tasks_page.dart';
import 'src/ui/widgets.dart';

/// 全局导航键：托盘菜单与退出确认要在没有页面 context 的地方弹对话框。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先自检再起应用：数据目录写不了、资源读不出来、Windows 缺 WebView2，
  // 这三样任一缺失后面都会以更难看的方式炸开，不如当场说清楚。
  // 只查 Windows，其它平台直接跳过（Android 的路径与依赖不同，不在本次范围）。
  if (DesktopShell.isSupported) {
    final report = await runStartupChecks(
      dataRoot: await _resolveStartupDataRoot(),
      isWindows: true,
    );
    if (!report.allRequiredOk) {
      runApp(StartupFailureApp(report: report));
      return;
    }
  }
  runApp(const BiliCrossApp());
}

/// 自检阶段的数据目录：此时 AppState 还没加载，只能按通道约定先算一份。
/// 与 AppState 用的是同一套判定（见 core/distribution.dart），不会打架。
Future<Directory> _resolveStartupDataRoot() async {
  final support = await getApplicationSupportDirectory();
  return resolveDataRoot(systemSupportDirectory: support);
}

class BiliCrossApp extends StatefulWidget {
  const BiliCrossApp({super.key});

  @override
  State<BiliCrossApp> createState() => _BiliCrossAppState();
}

class _BiliCrossAppState extends State<BiliCrossApp> {
  final Future<AppState> _loading = AppState.load();

  /// 开屏是否已经放完。null 表示还没判断（设置还没读出来）。
  bool? _splashDone;

  /// 需要显示的开屏图；没有就是 null。
  File? _splashImage;

  /// 开屏配置判完之后才有意义：只有「开启 + 图存在」才走开屏。
  void _prepareSplash(AppState state) {
    if (_splashDone != null) return;
    final settings = state.settings;
    final file = splashImageFile(state.store.root);
    final usable = settings.splashEnabled && file.existsSync();
    _splashImage = usable ? file : null;
    // 不显示开屏时直接标记完成，主界面立刻出来。
    _splashDone = !usable;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppState>(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // 还没读到设置，拿不到用户选的语言，这里先按中文出提示。
          const l10n = AppLocalizationsZh();
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: l10n.tr('app.name'),
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.tr('app.initFailed', {'error': '${snapshot.error}'}),
                  ),
                ),
              ),
            ),
          );
        }
        final state = snapshot.data;
        if (state == null) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        // 换语言必须重建 MaterialApp：locale 变了整棵树的 Localizations 都要换，
        // 只重建 AppShell 不够。所以监听放在 MaterialApp 外面这一层。
        // Windows 上把窗口与托盘接起来：只做平台外壳，业务动作走回调。
        // 失败只记日志，不影响应用本身（托盘不可用也得能用软件）。
        //
        // 注意：这里是 build()，可能被调用多次。必须**同步**置位守卫再启动异步初始化，
        // 否则并发进来会重复执行 initialize()，把 windowManager / trayManager
        // 的原生状态搞乱 —— 表现为窗口闪一下就自己关掉。
        if (!_shellAttachStarted) {
          _shellAttachStarted = true;
          unawaited(_attachDesktopShell(state));
        }
        _prepareSplash(state);
        final image = _splashImage;
        final showingSplash = _splashDone != true && image != null;
        // 开屏与主界面之间做交叉淡化：图渐隐、界面渐显，而不是硬切。
        // AnimatedSwitcher 按 key 区分两个子树（两个 MaterialApp 是不同实例），
        // 切换时同时跑淡出与淡入。
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: showingSplash
              ? MaterialApp(
                  key: const ValueKey<String>('splash'),
                  debugShowCheckedModeBanner: false,
                  home: SplashScreen(
                    image: image,
                    seconds: state.settings.splashSeconds,
                    onDone: () {
                      if (mounted) setState(() => _splashDone = true);
                    },
                  ),
                )
              : KeyedSubtree(
                  key: const ValueKey<String>('main'),
                  child: ListenableBuilder(
                    listenable: state,
                    builder: (context, _) => _buildApp(state),
                  ),
                ),
        );
      },
    );
  }

  DesktopShell? _shell;
  bool _shellAttachStarted = false;

  Future<void> _attachDesktopShell(AppState state) async {
    if (!DesktopShell.isSupported) return;
    final l10n = AppLocalizations.fromCode(state.settings.localeCode);
    final shell = _shell ??= DesktopShell(
      labels: DesktopShellLabels(
        show: l10n.tr('tray.show'),
        openFolder: l10n.tr('tray.folder'),
        pauseAll: l10n.tr('tray.pauseAll'),
        quit: l10n.tr('tray.quit'),
      ),
      onShow: () async {},
      onOpenFolder: () async {
        final dir = state.settings.downloadDir.trim();
        if (dir.isEmpty) return;
        // 用系统文件管理器打开下载目录；失败只记日志，不打断用户。
        try {
          await Process.run('explorer', <String>[dir]);
        } on Object catch (error) {
          LogStore.instance.add('托盘', '打开下载目录失败：$error');
        }
      },
      onPauseAll: () async {
        state.pauseAllActive();
      },
      onConfirmQuit: () async {
        if (state.activeTaskCount == 0) return true;
        final context = navigatorKey.currentContext;
        if (context == null) return true;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) {
            final t = AppLocalizations.of(context);
            return AlertDialog(
              title: Text(t.tr('quit.title')),
              content: Text(t.tr('quit.body')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(t.tr('common.cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(t.tr('quit.ok')),
                ),
              ],
            );
          },
        );
        // 用户取消：任务继续跑，什么都不做。
        return confirmed ?? false;
      },
    );
    // 并发守卫已在调用处（build 里同步置位 _shellAttachStarted）拦住了，
    // 这里不再需要 _shellAttached 二次判断。
    await shell.initialize(closeToTray: state.settings.closeToTray);
    // 设置里改了关闭行为，这里跟着换。
    state.addListener(() {
      shell.applyCloseBehavior(state.settings.closeToTray);
    });
  }

  Widget _buildApp(AppState state) {
    final l10n = AppLocalizations.fromCode(state.settings.localeCode);
    const seed = Color(0xff2f6f65);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      title: l10n.tr('app.name'),
      // 'system' 交给框架按系统语言挑，其余按设置锁定。
      locale: state.settings.localeCode == kLocaleSystem ? null : l10n.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      // GlobalMaterialLocalizations 提供「复制/剪切/粘贴/全选」等文本操作菜单的
      // 官方译文，长按菜单跟着 locale 走；下面四个 delegate 缺一不可。
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
          surface: const Color(0xfff6f7f5),
        ),
        scaffoldBackgroundColor: const Color(0xfff6f7f5),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xffd9dedb)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
        ),
      ),
      home: AppShell(state: state),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({required this.state, super.key});

  final AppState state;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;

  @override
  void initState() {
    super.initState();
    widget.state.refreshFfmpeg();
    widget.state.refreshAccount();
    // 启动不自动开跑：上次中断的任务会带着分片回到「等待」，
    // 队列要人点了任务页的「开始任务」才动，跟新入队的任务一个规矩。
    // （单个任务的「重试」「继续」仍是点了就跑。）
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdateOnce());
  }

  /// 启动后静默查一次更新：有新版弹说明弹窗，查不到提示一句，已是最新不出声。
  /// Android 与 Windows 都查：前者换侧载包，后者换安装包/便携包。
  Future<void> _checkUpdateOnce() async {
    if (!mounted) return;
    final platform = Theme.of(context).platform;
    if (platform != TargetPlatform.android &&
        platform != TargetPlatform.windows) {
      return;
    }
    final result = await checkForUpdate();
    if (!mounted) return;
    // Android 的 apk 由 CI 按 ABI 出包，当前只发 arm64；能装上就说明是这一种。
    await handleUpdateResult(
      context,
      result,
      notifyWhenUpToDate: false,
      androidAbi: Platform.isAndroid ? 'arm64-v8a' : null,
    );
  }

  List<NavigationDestination> _destinations(AppLocalizations l10n) => [
        NavigationDestination(
          icon: const Icon(Icons.add_link),
          label: l10n.tr('nav.download'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.downloading),
          label: l10n.tr('nav.tasks'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.account_circle_outlined),
          label: l10n.tr('nav.account'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.tune),
          label: l10n.tr('nav.settings'),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = widget.state;
    final pages = <Widget>[
      DownloadPage(state: state),
      TasksPage(state: state),
      AccountPage(state: state),
      SettingsPage(state: state),
    ];
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            return Scaffold(
              appBar: AppBar(
                title: Text(l10n.tr('app.name')),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Center(
                      child: StateChip(
                        text: state.queueRunning
                            ? l10n.tr('app.queueRunning')
                            : l10n.tr('app.dartEngine'),
                        tone: state.queueRunning ? 1 : 0,
                      ),
                    ),
                  ),
                ],
              ),
              body: Row(
                children: [
                  if (wide)
                    NavigationRail(
                      selectedIndex: index,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (value) => setState(() => index = value),
                      destinations: _destinations(l10n)
                          .map(
                            (item) => NavigationRailDestination(
                              icon: item.icon,
                              label: Text(item.label),
                            ),
                          )
                          .toList(),
                    ),
                  Expanded(child: pages[index]),
                ],
              ),
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: index,
                      onDestinationSelected: (value) => setState(() => index = value),
                      destinations: _destinations(l10n),
                    ),
            );
          },
        );
      },
    );
  }
}
