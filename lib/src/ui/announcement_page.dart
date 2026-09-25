import 'package:flutter/material.dart';

import '../core/announcement.dart';
import '../core/announcement_center.dart';
import '../i18n/app_localizations.dart';
import 'announcement_dialog.dart';
import 'palette.dart';
import 'widgets.dart';

/// 公告列表页：设置页「查看公告」进来。
///
/// 列的是**服务器当前仍有效的全部公告**（由后端按平台 / 版本 / 时间过滤），
/// 已读的也在 —— 已读只是不再弹窗，不影响回看。
class AnnouncementPage extends StatefulWidget {
  const AnnouncementPage({required this.center, super.key});

  final AnnouncementCenter center;

  @override
  State<AnnouncementPage> createState() => _AnnouncementPageState();
}

class _AnnouncementPageState extends State<AnnouncementPage> {
  /// 手动刷新。失败提示一句，并保留上一次的内容（不清空）。
  Future<void> _refresh() async {
    final ok = await widget.center.refresh(manual: true);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).tr('announcement.refreshFailed'),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('announcement.title')),
        actions: <Widget>[
          ListenableBuilder(
            listenable: widget.center,
            builder: (context, _) => IconButton(
              tooltip: l10n.tr('announcement.refresh'),
              icon: widget.center.loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: widget.center.loading ? null : _refresh,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.center,
        builder: (context, _) {
          final items = widget.center.items;
          final footer = _footer(l10n);
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: <Widget>[
                  EmptyState(
                    icon: Icons.campaign_outlined,
                    title: l10n.tr('announcement.emptyTitle'),
                    message: l10n.tr('announcement.emptyBody'),
                  ),
                  footer,
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: items.length + 1,
              separatorBuilder: (_, index) =>
                  SizedBox(height: index == items.length - 1 ? 0 : 10),
              itemBuilder: (context, index) {
                if (index == items.length) return footer;
                return _card(context, items[index]);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context, Announcement announcement) {
    final l10n = AppLocalizations.of(context);
    final center = widget.center;
    final unread = !center.isDismissed(announcement.id);
    final poll = announcement.poll;
    final status = <String>[
      if (unread) l10n.tr('announcement.unread'),
      if (poll != null)
        center.hasVoted(poll.id)
            ? l10n.tr('announcement.voted')
            : poll.open
                ? l10n.tr('announcement.hasPoll')
                : l10n.tr('announcement.pollClosed'),
    ].join(' · ');
    return Card(
      child: ListTile(
        leading: Icon(
          announcement.forced ? Icons.priority_high : Icons.campaign_outlined,
          color: announcement.forced ? kDanger : null,
        ),
        title: Text(
          announcement.title,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              announcement.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: kTextMuted),
            ),
            if (status.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                status,
                style: const TextStyle(fontSize: 11, color: kTextSubtle),
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        // ⚠️ 从列表点开是**主动查看**：不强制滑到底，不可关闭的公告也允许关 ——
        // 否则用户会被卡在设置页里出不去。
        onTap: () => showAnnouncementDialog(
          context,
          center: center,
          announcement: announcement,
          review: true,
        ),
      ),
    );
  }

  Widget _footer(AppLocalizations l10n) {
    final center = widget.center;
    final stamp = center.lastFetchAt;
    final text = center.failed
        ? l10n.tr('announcement.refreshFailed')
        : stamp == null
            ? l10n.tr('announcement.neverUpdated')
            : l10n.tr('announcement.updatedAt', {
                'time': _hhmm(stamp),
              });
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (center.failed) ...<Widget>[
            const Icon(Icons.cloud_off_outlined, size: 14, color: kTextMuted),
            const SizedBox(width: 6),
          ],
          Text(text, style: const TextStyle(fontSize: 12, color: kTextMuted)),
        ],
      ),
    );
  }

  static String _hhmm(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
