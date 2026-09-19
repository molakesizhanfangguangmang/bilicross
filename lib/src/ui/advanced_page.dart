import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/log_store.dart';
import '../i18n/app_localizations.dart';
import 'about_dialog.dart';
import 'anim_tuning_card.dart';
import 'log_page.dart';
import 'splash_card.dart';

/// 高级设置：低频、偏配置的项收在这里，设置主页只留常用项。
///
/// 语言不在这里——它是新用户最先要用的一项，放在主页更容易找到。
class AdvancedSettingsPage extends StatelessWidget {
  const AdvancedSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final logPath = LogStore.instance.filePath;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tr('settings.advanced'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
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
