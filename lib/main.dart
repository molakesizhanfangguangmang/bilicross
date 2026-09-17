import 'package:flutter/material.dart';

void main() => runApp(const BiliHarborApp());

class BiliHarborApp extends StatelessWidget {
  const BiliHarborApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xff2f6f65);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BiliHarbor',
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
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

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

  static const pages = <Widget>[
    DownloadPage(),
    TasksPage(),
    AccountPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Scaffold(
          appBar: AppBar(
            title: const Text('BiliHarbor'),
            actions: const [
              Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(child: _StatusBadge()),
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
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xffe6eee9),
        border: Border.all(color: const Color(0xffb8c9bf)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text('Dart 引擎', style: TextStyle(fontSize: 12)),
      ),
    );
  }
}

class PageFrame extends StatelessWidget {
  const PageFrame({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: '新建下载',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    labelText: '视频、番剧或分 P 地址',
                    hintText: 'https://www.bilibili.com/video/BV...',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: null,
                icon: const Icon(Icons.search),
                label: const Text('解析'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _EmptyState(
            icon: Icons.video_library_outlined,
            title: '等待解析',
            message: '解析结果会在这里显示分 P、视频流、音频流、字幕与封面。',
          ),
        ],
      ),
    );
  }
}

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageFrame(
      title: '下载任务',
      child: _EmptyState(
        icon: Icons.inbox_outlined,
        title: '暂无任务',
        message: '队列会区分等待、下载、合并、完成与失败状态。',
      ),
    );
  }
}

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: '账号与授权',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('WEB Cookie', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text('未配置', style: TextStyle(color: Color(0xff6d716f))),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.paste),
                        label: const Text('粘贴 Cookie'),
                      ),
                      OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.file_open),
                        label: const Text('导入 cookie.txt'),
                      ),
                      OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.language),
                        label: const Text('网页登录'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('APP Token', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text('需要先配置有效的 WEB Cookie', style: TextStyle(color: Color(0xff6d716f))),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('打开 APP 授权'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String engine = 'dart';

  @override
  Widget build(BuildContext context) {
    final windows = Theme.of(context).platform == TargetPlatform.windows;
    return PageFrame(
      title: '设置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: engine,
            decoration: const InputDecoration(
              labelText: '默认引擎',
              prefixIcon: Icon(Icons.memory),
            ),
            items: [
              const DropdownMenuItem(value: 'dart', child: Text('Dart 内置引擎')),
              if (windows)
                const DropdownMenuItem(
                  value: 'bbdown',
                  child: Text('BBDownNext 兼容引擎'),
                ),
            ],
            onChanged: (value) => setState(() => engine = value ?? 'dart'),
          ),
          const SizedBox(height: 12),
          const TextField(
            readOnly: true,
            decoration: InputDecoration(
              labelText: '下载目录',
              prefixIcon: Icon(Icons.folder_outlined),
              suffixIcon: Icon(Icons.folder_open),
              hintText: '尚未选择',
            ),
          ),
          const SizedBox(height: 12),
          const TextField(
            readOnly: true,
            decoration: InputDecoration(
              labelText: '混流方式',
              prefixIcon: Icon(Icons.merge_type),
              hintText: '仅封装合并，不转码',
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 280),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffd9dedb)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42, color: const Color(0xff65716c)),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
