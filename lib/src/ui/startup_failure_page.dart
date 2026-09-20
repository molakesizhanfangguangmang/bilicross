import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/startup_check.dart';
import '../i18n/app_localizations.dart';
import './palette.dart';

/// WebView2 运行时官方下载页（微软 Evergreen 引导安装包）。
const String kWebView2DownloadUrl =
    'https://developer.microsoft.com/microsoft-edge/webview2/';

/// 启动自检没通过时的阻塞页。
///
/// 不复用主应用外壳：此时设置还没读出来，语言未知（按系统语言挑），
/// 也不该让用户点进任何页面。只做两件事——说清楚缺什么、给一个退出按钮。
/// Windows 上退出即结束进程；其它平台只提示，不做（Android 不接自检）。
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({required this.report, super.key});

  final StartupReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.fromCode(
      AppLocalizations.resolveCode(kLocaleSystem),
    );
    const seed = Color(0xff2f6f65);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: l10n.tr('app.name'),
      locale: l10n.locale,
      supportedLocales: AppLocalizations.supportedLocales,
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
          surface: kSurfacePage,
        ),
        scaffoldBackgroundColor: kSurfacePage,
        useMaterial3: true,
      ),
      home: StartupFailurePage(report: report),
    );
  }
}

class StartupFailurePage extends StatelessWidget {
  const StartupFailurePage({required this.report, super.key});

  final StartupReport report;

  Future<void> _openDownload(BuildContext context) async {
    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(kWebView2DownloadUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (launched || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.tr('common.browserNotOpened')),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _exit() {
    // Windows / 桌面：环境不满足就直接结束进程，别留个死界面。
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failures = <CheckResult>[
      ...report.blocking,
      ...report.warnings,
    ];
    final webView2Blocked =
        report.blocking.any((r) => r.id == 'webview2');
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.tr('startup.title'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(l10n.tr('startup.body')),
                const SizedBox(height: 16),
                for (final item in failures) _CheckRow(item: item),
                if (webView2Blocked) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.tr('startup.webview2Hint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => _openDownload(context),
                    child: Text(l10n.tr('startup.webview2Download')),
                  ),
                ],
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _exit,
                    child: Text(l10n.tr('startup.exit')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.item});

  final CheckResult item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final detail = item.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.ok ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 18,
            color: item.ok ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.tr(item.labelKey)),
                if (!item.ok && detail != null && detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l10n.tr('startup.reason', {'detail': detail}),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
