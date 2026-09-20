import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import './palette.dart';

/// 空间链接弹窗：分「合集」「系列」两组列出该 UP 名下的条目。
///
/// 数据来自 `seasons_series_list`（一次请求）。选中的条目回调给宿主，
/// 由宿主决定怎么解析（合集走清单，系列走翻页）。
/// 风控 -352 会一路抛上来，由调用方的 catch 统一展示，不在这里吞掉。
class SeasonInfoSheet extends StatelessWidget {
  const SeasonInfoSheet({
    super.key,
    required this.future,
    required this.onPick,
  });

  /// 正在加载的列表请求（build 时才发起，避免无谓的提前请求）。
  final Future<SeasonInfoList> future;

  /// 用户点选某条后的回调。
  final void Function(SeasonInfoEntry entry) onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: FutureBuilder<SeasonInfoList>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text(
                '${snapshot.error}',
                style: const TextStyle(color: kWarning),
              );
            }
            final list = snapshot.data!;
            if (list.seasons.isEmpty && list.series.isEmpty) {
              return Text(l10n.tr('spaceSheet.empty'));
            }
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (list.seasons.isNotEmpty) ...<Widget>[
                      _GroupLabel(label: l10n.tr('spaceSheet.seasons')),
                      for (final entry in list.seasons)
                        _EntryTile(
                          entry: entry,
                          onTap: () {
                            Navigator.of(context).pop();
                            onPick(entry);
                          },
                        ),
                    ],
                    if (list.series.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      _GroupLabel(label: l10n.tr('spaceSheet.series')),
                      for (final entry in list.series)
                        _EntryTile(
                          entry: entry,
                          onTap: () {
                            Navigator.of(context).pop();
                            onPick(entry);
                          },
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: kTextMuted,
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});

  final SeasonInfoEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        entry.kind == SeasonInfoKind.season
            ? Icons.video_library_outlined
            : Icons.playlist_play,
        size: 20,
      ),
      title: Text(entry.title.isEmpty ? '—' : entry.title,
          style: const TextStyle(fontSize: 14)),
      trailing: Text(
        l10n.tr('manifest.sectionEpisodes', {'count': '${entry.total}'}),
        style: const TextStyle(fontSize: 12, color: kTextMuted),
      ),
      onTap: onTap,
    );
  }
}

/// 便捷入口：拿到 mid 后弹这个窗。
///
/// [onPick] 在弹窗关闭后回调（选中条目），由宿主决定怎么解析 ——
/// 合集走清单接口进选择页，系列暂时只给一句提示。
Future<void> showSeasonInfoSheet(
  BuildContext context,
  AppState state,
  int mid, {
  required void Function(SeasonInfoEntry entry) onPick,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SeasonInfoSheet(
      future: state.api
          .fetchSeasonInfoList(mid: mid, cookie: state.cookie.raw),
      onPick: onPick,
    ),
  );
}
