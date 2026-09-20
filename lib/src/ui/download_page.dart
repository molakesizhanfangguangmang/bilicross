import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/bili_url.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'expand_page_route.dart';
import 'season_info_sheet.dart';
import 'season_select_page.dart';
import 'widgets.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({required this.state, super.key});

  final AppState state;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.state.addressInput);
  int? _videoIndex;
  int? _audioIndex;

  /// 从空间弹窗选了合集后，正在拉整部清单。
  bool _seasonLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// -1 是「这条轨道不下载」，不能被 ??= 覆盖回默认值；越界则回落到默认勾选行。
  void _rememberSelection(ParsedMedia media) {
    _videoIndex ??= 0;
    if (_videoIndex! >= media.videos.length) {
      _videoIndex = media.videos.isEmpty ? -1 : 0;
    }
    _audioIndex ??= media.audios.isEmpty ? -1 : media.audios.length - 1;
    if (_audioIndex! >= media.audios.length) {
      _audioIndex = media.audios.isEmpty ? -1 : media.audios.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final media = state.parsed;
        if (media != null) {
          _rememberSelection(media);
        }
        return PageFrame(
          title: l10n.tr('download.title'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onChanged: (value) => state.addressInput = value,
                      onSubmitted: (value) => _parse(state, value),
                      decoration: InputDecoration(
                        labelText: l10n.tr('download.addressHint'),
                        hintText: 'https://www.bilibili.com/video/BV... b23.tv',
                        prefixIcon: const Icon(Icons.link),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: state.busy ? null : () => _parse(state, _controller.text),
                    icon: const Icon(Icons.search),
                    label: Text(l10n.tr('download.parse')),
                  ),
                ],
              ),
              if (state.notice.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(state.notice, style: const TextStyle(color: Color(0xff8a5b4a))),
              ],
              const SizedBox(height: 16),
              if (state.busy || _seasonLoading)
                const LinearProgressIndicator(minHeight: 2)
              else if (media == null)
                EmptyState(
                  icon: Icons.video_library_outlined,
                  title: l10n.tr('download.waiting'),
                  message: l10n.tr('download.waitingHint'),
                )
              else
                _result(context, state, media),
            ],
          ),
        );
      },
    );
  }

  Future<void> _parse(AppState state, String value) async {
    _videoIndex = null;
    _audioIndex = null;
    final target = BiliUrl.parse(value);
    // 空间链接不是「一个视频」，没有单集可解析 —— 弹窗列出该 UP 的合集与系列，
    // 选中哪条就按哪条拉清单进选择页。
    if (target.kind == TargetKind.space && target.mid != null) {
      await _openSpaceSheet(state, target.mid!);
      return;
    }
    // 空间 lists 链接（带 mid 的合集入口）直接拉清单进选择页。
    // ⚠️ 不能走单集解析：占位的那一集来自清单接口，而清单接口**不返回 cid**，
    // 拿 cid 0 去请求 playurl 必然失败 —— 这条入口以前就是这么挂的。
    final seasonId = target.seasonId ?? 0;
    if (target.kind == TargetKind.ugcSeason &&
        target.mid != null &&
        seasonId > 0) {
      await _openSeason(
        state,
        target.mid!,
        SeasonInfoEntry(
          id: seasonId,
          title: '',
          total: 0,
          kind: SeasonInfoKind.season,
        ),
      );
      return;
    }
    await state.parseAddress(value);
  }

  /// 空间链接 → 弹窗选合集 → 拉整部清单 → 进合集选择页。
  Future<void> _openSpaceSheet(AppState state, int mid) async {
    await showSeasonInfoSheet(
      context,
      state,
      mid,
      onPick: (entry) => _openSeason(state, mid, entry),
    );
  }

  Future<void> _openSeason(
    AppState state,
    int mid,
    SeasonInfoEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _seasonLoading = true);
    try {
      // 合集与系列走各自的翻页接口，返回形状一样（archives[]）。
      final info = entry.kind == SeasonInfoKind.series
          ? await state.api.fetchSeriesArchives(
              seriesId: entry.id,
              mid: mid,
              cookie: state.cookie.raw,
            )
          : await state.api.fetchUgcSeasonArchives(
              seasonId: entry.id,
              mid: mid,
              cookie: state.cookie.raw,
            );
      if (!mounted) return;
      // 合集清单的 meta 里带标题，直接用；系列没有，才用弹窗那条的名称补。
      final manifest = (info.season?.title.isEmpty ?? true)
          ? info.season?.withTitle(entry.title)
          : info.season;
      if (manifest == null || manifest.totalEpisodes == 0) {
        state.showNotice(l10n.tr('spaceSheet.noEpisodes'));
        return;
      }
      openSeasonSelectPage(context, state, manifest);
    } on Exception catch (error) {
      if (!mounted) return;
      state.showNotice('$error');
    } finally {
      if (mounted) setState(() => _seasonLoading = false);
    }
  }

  Widget _result(BuildContext context, AppState state, ParsedMedia media) {
    final l10n = AppLocalizations.of(context);
    final videoIndex = (_videoIndex ?? 0).clamp(-1, media.videos.length - 1);
    final audioIndex = (_audioIndex ?? (media.audios.isEmpty ? -1 : media.audios.length - 1))
        .clamp(-1, media.audios.length - 1);
    final canStart = videoIndex >= 0 || audioIndex >= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: media.info.title.isEmpty ? l10n.tr('download.result') : media.info.title,
          trailing: StateChip(text: media.channel),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InfoLine(
                label: l10n.tr('download.id'),
                value:
                    '${media.info.bvid.isEmpty ? 'av${media.info.aid}' : media.info.bvid} · cid ${media.page.cid}',
              ),
              if (media.info.owner.isNotEmpty)
                InfoLine(label: l10n.tr('download.uploader'), value: media.info.owner),
              InfoLine(
                label: l10n.tr('download.part'),
                value: '${media.page.page} / ${media.info.pages.length} · ${media.page.part}',
              ),
              InfoLine(
                label: l10n.tr('download.duration'),
                value: formatDuration(media.durationSec),
              ),
              if (media.page.epId > 0) InfoLine(label: 'ep', value: '${media.page.epId}'),
            ],
          ),
        ),
        // 这条视频属于某个合集时，给一个**入口卡片**而不是直接铺开清单：
        // 200+ 集的清单铺在下载页会把单集那套（选流、加入任务）挤得看不见。
        // 想下这一集 → 用上面的单集流程；想下合集 → 点这里进选择页。
        if (media.info.season != null) ...<Widget>[
          const SizedBox(height: 12),
          _SeasonEntryCard(
            manifest: media.info.season!,
            onOpen: (rect) => openSeasonSelectPage(
              context,
              state,
              media.info.season!,
              sourceRect: rect,
            ),
          ),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: l10n.tr('download.videoStreams'),
          child: Column(
            children: [
              ChoiceTile(
                selected: videoIndex < 0,
                onTap: () => setState(() => _videoIndex = -1),
                title: l10n.tr('download.noVideo'),
              ),
              for (var index = 0; index < media.videos.length; index++)
                ChoiceTile(
                  selected: index == videoIndex,
                  onTap: () => setState(() => _videoIndex = index),
                  title: '${media.videos[index].label} · ${media.videos[index].detail}',
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: l10n.tr('download.audioStreams'),
          child: media.audios.isEmpty
              ? Text(l10n.tr('download.noAudioTrack'))
              : Column(
                  children: [
                    ChoiceTile(
                      selected: audioIndex < 0,
                      onTap: () => setState(() => _audioIndex = -1),
                      title: l10n.tr('download.noAudio'),
                    ),
                    for (var index = 0; index < media.audios.length; index++)
                      ChoiceTile(
                        selected: index == audioIndex,
                        onTap: () => setState(() => _audioIndex = index),
                        title: '${media.audios[index].label} · ${media.audios[index].detail}',
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 「加入任务」只入队：队列要人去任务页点「开始任务」才跑。
              FilledButton.icon(
                onPressed: !canStart
                    ? null
                    : () => _submit(
                          context,
                          state,
                          media,
                          videoIndex,
                          audioIndex,
                          startNow: false,
                        ),
                icon: const Icon(Icons.playlist_add),
                label: Text(
                  canStart
                      ? l10n.tr(videoIndex >= 0 && audioIndex >= 0
                          ? 'download.enqueueVideoAudio'
                          : videoIndex >= 0
                              ? 'download.enqueueVideoOnly'
                              : 'download.enqueueAudioOnly')
                      : l10n.tr('download.needOneTrack'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: !canStart
                    ? null
                    : () => _submit(
                          context,
                          state,
                          media,
                          videoIndex,
                          audioIndex,
                          startNow: true,
                        ),
                icon: const Icon(Icons.download),
                label: Text(l10n.tr('download.startNow')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 入队与开跑分开：入队本身不动网络，只有「立即开始下载」顺带把队列跑起来。
  void _submit(
    BuildContext context,
    AppState state,
    ParsedMedia media,
    int videoIndex,
    int audioIndex, {
    required bool startNow,
  }) {
    state.enqueue(
      video: videoIndex >= 0 ? media.videos[videoIndex] : null,
      audio: audioIndex >= 0 ? media.audios[audioIndex] : null,
      engine: 'dart',
    );
    if (startNow) {
      state.pumpQueue();
    }
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          startNow
              ? l10n.tr('download.enqueuedStart')
              : l10n.tr('download.enqueuedWait'),
        ),
      ),
    );
  }
}

/// 「这个视频属于合集」入口卡片。
///
/// 只给入口、不铺清单 —— 单集下载和合集下载是两条路，互不挤占。
class _SeasonEntryCard extends StatelessWidget {
  const _SeasonEntryCard({required this.manifest, required this.onOpen});

  final SeasonManifest manifest;
  final void Function(Rect? sourceRect) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final key = GlobalKey();
    return SectionCard(
      title: manifest.title.isEmpty
          ? l10n.tr('manifest.untitled')
          : manifest.title,
      trailing: const Icon(Icons.chevron_right),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.tr('manifest.entryHint'),
            style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.tr('manifest.summary', {
              'episodes': '${manifest.totalEpisodes}',
              'sections': '${manifest.sections.length}',
            }),
            style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: key,
              onPressed: () => onOpen(globalRectOf(key.currentContext!)),
              icon: const Icon(Icons.checklist),
              label: Text(l10n.tr('manifest.entryOpen')),
            ),
          ),
        ],
      ),
    );
  }
}
