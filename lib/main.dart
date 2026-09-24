import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app_state.dart';
import 'src/core/background_config.dart';
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
import './src/ui/palette.dart';

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
        // ⚠️ 监听的是 `shellView` 而不是 AppState 本身：外壳只依赖语言、品牌色、
        // 队列开关与风控标记，其余通知（进度、提示、任务增删…）一律挡在外面，
        // 否则下载期每秒几十次的进度都会把 MaterialApp 与 ThemeData 重算一遍。
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
                    listenable: state.shellView,
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
    // 品牌色跟着设置走（预设五种，见 core/models.dart 的 kThemeSeeds）。
    // ⚠️ 语义色（缺档的琥珀、风控的红）不在这里 —— 它们固定，见 ui/palette.dart。
    final seed = themeSeedOf(state.settings.themeId);
    // 提前取出配色：导航栏的指示器色与选中态图标色都要引用它。
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: kSurfacePage,
    );
    // 背景：浓度 > 0 **且**图确实在磁盘上，才算「有背景」。
    // 不额外存开关 —— 0% 就是关，文件在不在就是图在不在。
    final backgroundFile = backgroundImageFile(state.store.root);
    final backgroundOpacity = clampBackgroundOpacity(
      state.settings.backgroundOpacity,
    );
    final hasBackground = backgroundOpacity > kBackgroundMinOpacity &&
        backgroundFile.existsSync();
    // 界面不透明度：100% 时**一个主题字段都不覆盖** —— 默认值必须与旧版像素级一致。
    // 低于 100% 才是「给同一批底色在运行时加 alpha」，不是换成别的色。
    final uiOpacity = clampUiOpacity(state.settings.uiOpacity);
    final translucentUi = uiOpacity < kUiMaxOpacity;
    final backgroundFit = normalizeBackgroundFit(state.settings.backgroundFit);
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
      // 背景层垫在所有路由**之下**：页面怎么切换它都不动。
      // ⚠️ 兜底色不能省：只把 `scaffoldBackgroundColor` 改透明的话，透明处会露到
      // **窗口底色**（Windows 白/黑、安卓黑），而不是页面底。
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ColoredBox(color: kSurfacePage),
          if (hasBackground)
            _backgroundImage(
              file: backgroundFile,
              opacity: backgroundOpacity,
              fit: backgroundFit,
            ),
          ?child,
        ],
      ),
      theme: ThemeData(
        colorScheme: scheme,
        // 只有开了背景才把页面底改透明，让底下那层背景透上来。
        scaffoldBackgroundColor:
            hasBackground ? Colors.transparent : kSurfacePage,
        useMaterial3: true,
        // ⚠️ 界面不透明度只在 < 100% 时才覆盖底色；100% 时全为 null、
        // 回落到 M3 默认（`surface` / `surfaceContainer` / `surfaceContainerLow`），
        // 与旧版完全一致。`palette.dart` 一个字都不改。
        appBarTheme: translucentUi
            ? AppBarTheme(
                backgroundColor: scheme.surface.withValues(alpha: uiOpacity),
                // M3 的滚动态会再盖一层 surfaceTint，把透明效果吃掉。
                scrolledUnderElevation: 0,
              )
            : null,
        // 选中项的指示器用主色（深墨绿）实心填充、图标转白。
        // 默认的 secondaryContainer 太浅，几乎与背景同亮度，看不出选中状态。
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: translucentUi
              ? scheme.surfaceContainer.withValues(alpha: uiOpacity)
              : null,
          indicatorColor: scheme.primary,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            );
          }),
        ),
        // 宽屏走 NavigationRail，配色要与底部导航保持一致，否则两端观感不同。
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: translucentUi
              ? scheme.surface.withValues(alpha: uiOpacity)
              : null,
          indicatorColor: scheme.primary,
          selectedIconTheme: IconThemeData(color: scheme.onPrimary),
          unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
          selectedLabelTextStyle: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
          unselectedLabelTextStyle: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
          ),
        ),
        // 卡片也跟界面不透明度走：`SectionCard` 是裸 `Card`（ui/widgets.dart），
        // 改这一处就能覆盖全部卡片。
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: translucentUi
              ? scheme.surfaceContainerLow.withValues(alpha: uiOpacity)
              : null,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: kBorder),
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

  /// 背景图。
  ///
  /// ⚠️ 解码尺寸封顶（[kBackgroundDecodeCap]）而不是按窗口算：按窗口算的话
  /// 拖一次窗口就换一次解码目标，得再引一层 resize 防抖；固定上限既压住内存，
  /// 也省掉防抖。
  Widget _backgroundImage({
    required File file,
    required double opacity,
    required String fit,
  }) {
    final tile = fit == kBackgroundFitTile;
    return Image(
      image: ResizeImage(
        FileImage(file),
        width: kBackgroundDecodeCap,
        height: kBackgroundDecodeCap,
        policy: ResizeImagePolicy.fit,
      ),
      opacity: AlwaysStoppedAnimation<double>(opacity),
      fit: tile
          ? BoxFit.none
          : (fit == kBackgroundFitContain ? BoxFit.contain : BoxFit.cover),
      repeat: tile ? ImageRepeat.repeat : ImageRepeat.noRepeat,
      // 图有可能在读出与绘制之间被外部删掉，别让异常冒到渲染层。
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
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

  /// 设置页的 state，用来触发保存（顶部那个按钮在外壳里）。
  final GlobalKey<SettingsPageState> _settingsKey =
      GlobalKey<SettingsPageState>();

  /// 设置页有没有未保存的改动 —— 顶部保存按钮据此置灰。
  final ValueNotifier<bool> _settingsCanSave = ValueNotifier<bool>(false);

  /// 设置页在导航里的序号（保存按钮只在这一页出现）。
  static const int _settingsIndex = 3;

  @override
  void dispose() {
    _settingsCanSave.dispose();
    super.dispose();
  }

  /// 风控提示是否已经弹出（避免每帧重复弹）。
  bool _riskDialogOpen = false;

  @override
  void initState() {
    super.initState();
    // ⚠️ 这两次刷新**不能**在这里直接调 —— initState 跑在 build 期间
    // （element 正在 mount），而 `refreshAccount()` 在第一个 `await` 之前
    // 就会同步 `notifyListeners()`（空 Cookie 那条路是纯同步的），于是撞上
    // 「setState() or markNeedsBuild() called during build」断言：
    // debug 下每次启动冒一段红字，release 里断言被编译掉、不崩，但那一次通知
    // 等于丢在当前帧。放到首帧之后再跑就没事 —— 代价是一帧延迟，用户看不出来，
    // 何况这两件事本来就是异步的。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.state.refreshFfmpeg();
      widget.state.refreshAccount();
      // 启动不自动开跑：上次中断的任务会带着分片回到「等待」，
      // 队列要人点了任务页的「全部开始」才动，跟新入队的任务一个规矩。
      // （单个任务的「重试」「继续」仍是点了就跑。）
      _checkUpdateOnce();
    });
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

  /// 风控 -352：弹一次窗，恢复完全手动 —— 不等冷却、不自动重试。
  /// 点「恢复」从停下的那一集接着走；点「先放着」只关窗，队列保持停手。
  void _maybeShowRiskDialog(AppState state, AppLocalizations l10n) {
    if (!state.riskControlHit || _riskDialogOpen) return;
    _riskDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _riskDialogOpen = false;
        return;
      }
      final resume = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.tr('risk.title')),
          content: Text(l10n.tr('risk.body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.tr('risk.later')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.tr('risk.resume')),
            ),
          ],
        ),
      );
      _riskDialogOpen = false;
      if (!mounted) return;
      if (resume ?? false) {
        state.resumeAfterRiskControl();
      } else {
        state.dismissRiskControl();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = widget.state;
    _maybeShowRiskDialog(state, l10n);
    final pages = <Widget>[
      DownloadPage(state: state),
      TasksPage(state: state),
      AccountPage(state: state),
      SettingsPage(
        state: state,
        canSave: _settingsCanSave,
        key: _settingsKey,
      ),
    ];
    // ⚠️ 这里不要再套一层监听 AppState 的 ListenableBuilder：外壳本来就由
    // `_buildApp` 外层那个订阅 `shellView` 的构建器重建，两层监听同一个源
    // 只会让每次通知都把壳（含 ThemeData 与整列导航）重建两遍。
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Scaffold(
          appBar: AppBar(
            // ⚠️ 标题显示**当前页名**，不再是应用名 ——
            // 以前是「AppBar 显示应用名 + 内容区再显示一次页名」，
            // 手机上两条标题栏叠着，白占一整行。
            title: Text(_destinations(l10n)[index].label),
            actions: [
              // 保存按钮只在设置页出现；没有未保存的改动时置灰不可点。
              if (index == _settingsIndex)
                ValueListenableBuilder<bool>(
                  valueListenable: _settingsCanSave,
                  builder: (context, canSave, _) => Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: TextButton.icon(
                      onPressed: canSave
                          ? () => _settingsKey.currentState?.save()
                          : null,
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: Text(l10n.tr('settings.save')),
                    ),
                  ),
                ),
              // 只在队列真的在跑时显示状态标，空闲时不再占位置
              // （2026-09-24 去掉了原来的「Dart 引擎」标）。
              // 安卓端的设置页仍然隐藏：那里标题栏已有保存按钮。
              if (state.queueRunning &&
                  (!Platform.isAndroid || index != _settingsIndex))
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: StateChip(
                      text: l10n.tr('app.queueRunning'),
                      tone: 1,
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
  }
}
