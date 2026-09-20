import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/log_store.dart';
import '../i18n/app_localizations.dart';
import 'about_dialog.dart';
import 'anim_tuning_card.dart';
import 'log_page.dart';
import 'splash_card.dart';
import 'widgets.dart';

/// 高级设置：低频、偏配置的项收在这里，设置主页只留常用项。
///
/// 语言不在这里——它是新用户最先要用的一项，放在主页更容易找到。
/// 「网络与高级」（代理 / UA / AppKey / AppSec）2026-09-20 从主页搬了过来。
class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage> {
  late final TextEditingController _proxy =
      TextEditingController(text: widget.state.settings.proxy);
  late final TextEditingController _userAgent =
      TextEditingController(text: widget.state.settings.userAgent);
  late final TextEditingController _appKey =
      TextEditingController(text: widget.state.settings.appKey);
  late final TextEditingController _appSec =
      TextEditingController(text: widget.state.settings.appSec);

  @override
  void dispose() {
    _proxy.dispose();
    _userAgent.dispose();
    _appKey.dispose();
    _appSec.dispose();
    super.dispose();
  }

  /// 只保存这一页的字段，不动主页那些。
  Future<void> _save() async {
    final settings = widget.state.settings;
    settings.proxy = _proxy.text.trim();
    settings.userAgent = _userAgent.text.trim();
    settings.appKey = _appKey.text.trim();
    settings.appSec = _appSec.text.trim();
    await widget.state.saveSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).tr('settings.saved'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final logPath = LogStore.instance.filePath;
    final state = widget.state;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tr('settings.advanced'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // 配置项在前，排错用的日志在后。
          SectionCard(
            title: l10n.tr('settings.network'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextField(
                  controller: _proxy,
                  decoration: InputDecoration(
                    labelText: l10n.tr('settings.proxy'),
                    hintText: 'http://host:port',
                    prefixIcon: const Icon(Icons.lan_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _userAgent,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'User-Agent',
                    hintText: l10n.tr('settings.uaHint'),
                    helperText: l10n.tr('settings.uaHelper'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _appKey,
                  decoration: const InputDecoration(labelText: 'AppKey'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _appSec,
                  decoration: const InputDecoration(labelText: 'AppSec'),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.tr('settings.appKeyHint'),
                  style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(l10n.tr('settings.save')),
            ),
          ),
          const SizedBox(height: 16),
          SplashCard(state: state),
          // 动画调节：长按设置页的「高级设置」入口解锁后才出现，解锁不可逆。
          if (state.settings.animTuningUnlocked) ...<Widget>[
            const SizedBox(height: 12),
            AnimTuningCard(state: state),
          ],
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(l10n.tr('settings.logs')),
              subtitle: Text(
                logPath == null
                    ? l10n.tr('settings.logsHint')
                    : l10n.tr('settings.logFile', {'path': logPath}),
                style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const LogPage(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.tr('settings.about')),
              subtitle: Text(
                l10n.tr('settings.aboutHint'),
                style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAppAboutDialog(context),
            ),
          ),
        ],
      ),
    );
  }
}
