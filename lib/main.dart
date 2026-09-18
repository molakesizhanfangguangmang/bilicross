import 'package:flutter/material.dart';

import 'src/app_state.dart';
import 'src/core/update_check.dart';
import 'src/i18n/app_localizations.dart';
import 'src/ui/about_dialog.dart';
import 'src/ui/account_page.dart';
import 'src/ui/download_page.dart';
import 'src/ui/settings_page.dart';
import 'src/ui/tasks_page.dart';
import 'src/ui/widgets.dart';

void main() => runApp(const BiliCrossApp());

class BiliCrossApp extends StatefulWidget {
  const BiliCrossApp({super.key});

  @override
  State<BiliCrossApp> createState() => _BiliCrossAppState();
}

class _BiliCrossAppState extends State<BiliCrossApp> {
  final Future<AppState> _loading = AppState.load();

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
        return ListenableBuilder(
          listenable: state,
          builder: (context, _) => _buildApp(state),
        );
      },
    );
  }

  Widget _buildApp(AppState state) {
    final l10n = AppLocalizations.fromCode(state.settings.localeCode);
    const seed = Color(0xff2f6f65);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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

  /// 启动后静默查一次更新：有新版弹确认框，查不到提示一句，已是最新不出声。
  /// 目前只给 Android 侧载包用，其它平台不显示「检测更新」也没必要去查。
  Future<void> _checkUpdateOnce() async {
    if (!mounted || Theme.of(context).platform != TargetPlatform.android) {
      return;
    }
    final result = await checkForUpdate();
    if (!mounted) return;
    await handleUpdateResult(context, result, notifyWhenUpToDate: false);
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
