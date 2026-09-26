import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/log_store.dart';
import '../i18n/app_localizations.dart';
import 'about_dialog.dart';
import 'anim_tuning_card.dart';
import 'announcement_page.dart';
import 'expand_page_route.dart';
import 'log_page.dart';
import 'splash_card.dart';
import 'widgets.dart';
import 'palette.dart';

/// 高级设置：低频、偏配置的项收在这里，设置主页只留常用项。
///
/// 语言不在这里——它是新用户最先要用的一项，放在主页更容易找到。
/// 网络相关的项（代理 / UA / AppKey / AppSec）2026-09-20 从主页搬了过来，
/// 2026-09-21 起拆成两张卡：「网络」（代理 / UA，管请求怎么发出去）与
/// 「App 参数」（AppKey / AppSec，申请 APP 授权码用）。
class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage> {
  final GlobalKey _announcementKey = GlobalKey();
  final GlobalKey _logsKey = GlobalKey();

  late final TextEditingController _proxy =
      TextEditingController(text: widget.state.settings.proxy);
  late final TextEditingController _userAgent =
      TextEditingController(text: widget.state.settings.userAgent);
  late final TextEditingController _appKey =
      TextEditingController(text: widget.state.settings.appKey);
  late final TextEditingController _appSec =
      TextEditingController(text: widget.state.settings.appSec);

  /// 把这一页的字段写进设置对象。
  void _writeFields() {
    final settings = widget.state.settings;
    settings.proxy = _proxy.text.trim();
    settings.userAgent = _userAgent.text.trim();
    settings.appKey = _appKey.text.trim();
    settings.appSec = _appSec.text.trim();
  }

  /// 离开这一页时自动保存。
  ///
  /// ⚠️ 为什么不给保存按钮：这几个字段全是文本框，没有"临时改一下再撤销"的用法，
  /// 改完就走是最自然的动作；多一个按钮反而多一步。主页那边保留按钮是因为
  /// 它有下拉框、目录选择器这类"选择型"字段，显式保存更稳。
  /// 代价是没有"取消"出口 —— 但改错了再进来改回来就行，不会造成不可恢复的后果。
  @override
  void dispose() {
    _writeFields();
    // 不 await：dispose 里没法等，落盘失败只写日志。
    unawaited(widget.state.saveSettings());
    _proxy.dispose();
    _userAgent.dispose();
    _appKey.dispose();
    _appSec.dispose();
    super.dispose();
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
          // ⚠️ 外观（主题色）2026-09-24 挪回了设置主页 —— 那是「点了就想看效果」
          // 的项，藏在二级页里不合适。
          // 网络：决定「请求怎么发出去」的两项 —— 代理与 User-Agent。
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
              ],
            ),
          ),
          const SizedBox(height: 12),
          // App 参数：申请 APP 授权码用的 AppKey / AppSec。
          SectionCard(
            title: l10n.tr('settings.appParams'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
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
                  style: const TextStyle(fontSize: 12, color: kTextMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.tr('settings.advancedAutoSave'),
            style: const TextStyle(fontSize: 12, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          SplashCard(state: state),
          // 动画调节：长按设置页的「高级设置」入口解锁后才出现，解锁不可逆。
          if (state.settings.animTuningUnlocked) ...<Widget>[
            const SizedBox(height: 12),
            AnimTuningCard(state: state),
          ],
          const SizedBox(height: 12),
          // 公告入口：2026-09-25 从设置主页挪来 —— 与日志 / 关于同类，
          // 都是低频的「查看」入口。
          // ⚠️ 单订阅公告中心而不是 AppState：公告中心是独立的 ChangeNotifier，
          // 不走 AppState 的通知边界。角标是未读条数。
          ListenableBuilder(
            listenable: state.announcements,
            builder: (context, _) {
              final unread = state.announcements.unreadCount;
              return Card(
                key: _announcementKey,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(Icons.campaign_outlined),
                  title: Text(l10n.tr('announcement.view')),
                  subtitle: Text(
                    l10n.tr('announcement.viewHint'),
                    style: const TextStyle(fontSize: 12, color: kTextMuted),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (unread > 0) ...<Widget>[
                        StateChip(text: '$unread', tone: 1),
                        const SizedBox(width: 6),
                      ],
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    ExpandPageRoute<void>(
                      sourceRect:
                          globalRectOf(_announcementKey.currentContext!),
                      duration: Duration(
                        milliseconds: state.settings.animDurationMs,
                      ),
                      curveName: state.settings.animCurve,
                      style: state.settings.animStyle,
                      builder: (context) => AnnouncementPage(
                        center: state.announcements,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Card(
            key: _logsKey,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(l10n.tr('settings.logs')),
              subtitle: Text(
                logPath == null
                    ? l10n.tr('settings.logsHint')
                    : l10n.tr('settings.logFile', {'path': logPath}),
                style: const TextStyle(fontSize: 12, color: kTextMuted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                ExpandPageRoute<void>(
                  sourceRect: globalRectOf(_logsKey.currentContext!),
                  duration: Duration(
                    milliseconds: state.settings.animDurationMs,
                  ),
                  curveName: state.settings.animCurve,
                  style: state.settings.animStyle,
                  builder: (context) => LogPage(state: state),
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
                style: const TextStyle(fontSize: 12, color: kTextMuted),
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
