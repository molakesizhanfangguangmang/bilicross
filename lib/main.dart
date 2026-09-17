import 'package:flutter/material.dart';

import 'src/app_state.dart';
import 'src/core/update_check.dart';
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
    const seed = Color(0xff2f6f65);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '逸轨',
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
      home: FutureBuilder<AppState>(
        future: _loading,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('初始化失败：${snapshot.error}'),
                ),
              ),
            );
          }
          final state = snapshot.data;
          if (state == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return AppShell(state: state);
        },
      ),
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

  static const destinations = <NavigationDestination>[
    NavigationDestination(icon: Icon(Icons.add_link), label: '下载'),
    NavigationDestination(icon: Icon(Icons.downloading), label: '任务'),
    NavigationDestination(icon: Icon(Icons.account_circle_outlined), label: '账号'),
    NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
  ];

  @override
  void initState() {
    super.initState();
    widget.state.refreshFfmpeg();
    widget.state.refreshAccount();
    widget.state.pumpQueue();
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

  @override
  Widget build(BuildContext context) {
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
                title: const Text('逸轨'),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Center(
                      child: StateChip(
                        text: state.queueRunning ? '队列运行中' : 'Dart 引擎',
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
                      destinations: destinations
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
                      destinations: destinations,
                    ),
            );
          },
        );
      },
    );
  }
}
