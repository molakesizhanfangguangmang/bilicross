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
import './palette.dart';

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
      // 这一页不显示逐任务进度，订阅不含进度的视图：后台在下东西时
      // 停在解析页也不会被每秒几十次的进度通知拖着重建。
      listenable: state.stableView,
      builder: (context, _) {
        final media = state.parsed;
        if (media != null) {
          _rememberSelection(media);
        }
        return PageFrame(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 地址输入行是这一页唯一的常驻控件，默认态下面没有任何卡片 ——
              // 开了背景或卡片 < 100% 时给它一块跟卡片同源的底，别让整页「全透明」。
              PanelBox(
                padding: const EdgeInsets.all(12),
                child: Row(
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
                      onPressed:
                          state.busy ? null : () => _parse(state, _controller.text),
                      icon: const Icon(Icons.search),
                      label: Text(l10n.tr('download.parse')),
                    ),
                  ],
                ),
              ),
              if (state.notice.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(state.notice, style: const TextStyle(color: kNoticeText)),
              ],
              const SizedBox(height: 16),
              if (state.busy || _seasonLoading)
                const LinearProgressIndicator(minHeight: 2)
              else if (state.pendingSeason != null)
                _pendingSeasonResult(context, state, state.pendingSeason!)
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

  /// 空间链接 / lists 链接拉到的合集：**先在首页给一张入口卡片**，
  /// 点进去才铺清单 —— 与「视频链接带合集」那条路一致，不直接跳页。
  Widget _pendingSeasonResult(
    BuildContext context,
    AppState state,
    SeasonManifest manifest,
  ) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SeasonEntryCard(
          manifest: manifest,
          hint: l10n.tr('manifest.entryHintLink'),
          onOpen: (rect) => openSeasonSelectPage(
            context,
            state,
            manifest,
            sourceRect: rect,
          ),
        ),
      ],
    );
  }

  /// 选分 P：**多选**，跟合集那套一致。
  ///
  /// 200 P 的视频一个个点会累死，所以给全选 / 清空，选完直接批量加入任务
  /// （只登记，开跑时逐 P 解析）。只勾一个时另给「只看这一 P」，
  /// 切过去重新解析 —— 解析一次只处理一个 cid，流地址按 cid 取，没法本地换。
  Future<void> _pickPage(AppState state, ParsedMedia media) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showDialog<_PagePick>(
      context: context,
      builder: (dialogContext) => _PagePickerDialog(media: media),
    );
    if (picked == null || !mounted) return;

    if (picked.pages.isNotEmpty) {
      final outcome = state.enqueuePages(
        media: media,
        pages: picked.pages,
        engine: 'dart',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.tr('manifest.batchResult', {
            'enqueued': '${outcome.enqueued}',
            'skipped': '${outcome.skipped}',
            'renamed': '${outcome.renamed}',
          })),
        ),
      );
      return;
    }
    _videoIndex = null;
    _audioIndex = null;
    await state.parseAddress(state.addressInput, pageOverride: picked.page);
  }

  Future<void> _parse(AppState state, String value) async {
    // 解析后收键盘：软键盘还挡着下面，点「立即开始下载」前先收掉。
    FocusManager.instance.primaryFocus?.unfocus();
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
      // ⚠️ 不直接跳选集页：回到首页给一张入口卡片，用户点进去才铺清单 ——
      // 与「视频链接带合集」那条路一致（用户 2026-09-20 明确要求）。
      state.showSeasonEntry(manifest);
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
    // 多 P 视频才在流卡片上标出是哪个 P、才给换 P 的入口 —— 单 P 视频不添乱。
    final manyParts = media.info.pages.length > 1;
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
          // 多 P 视频在标题里带出当前是哪个 P：选流时就地知道这组流属于谁，
          // 不必回头看上面的信息卡。换 P 的入口也放这里，两件事同一块区域。
          title: manyParts
              ? l10n.tr('download.videoStreamsPart', {
                  'page': '${media.page.page}',
                  'total': '${media.info.pages.length}',
                })
              : l10n.tr('download.videoStreams'),
          // 换 P 走 _pickPage：解析只取一个分 P，换 P 得重新解析那一 P。
          trailing: manyParts
              ? TextButton.icon(
                  onPressed: () => _pickPage(state, media),
                  icon: const Icon(Icons.list_alt, size: 16),
                  label: Text(l10n.tr('download.pickPageAction')),
                )
              : null,
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
              // 「加入任务」只入队：队列要人去任务页点「全部开始」才跑。
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
  const _SeasonEntryCard({
    required this.manifest,
    required this.onOpen,
    this.hint,
  });

  final SeasonManifest manifest;
  final void Function(Rect? sourceRect) onOpen;

  /// 说明文案。视频带合集时是「这个视频属于该合集」；
  /// 从空间/lists 链接进来时没有「这个视频」，换一句。
  final String? hint;

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
            hint ?? l10n.tr('manifest.entryHint'),
            style: const TextStyle(fontSize: 12, color: kTextMuted),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.tr('manifest.summary', {
              'episodes': '${manifest.totalEpisodes}',
              'sections': '${manifest.sections.length}',
            }),
            style: const TextStyle(fontSize: 12, color: kTextMuted),
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

/// 选集弹窗的结果：要么批量加入，要么只看某一 P。
class _PagePick {
  const _PagePick.enqueue(this.pages) : page = 0;
  const _PagePick.preview(this.page) : pages = const <int>{};

  /// 批量加入的分 P 集合（空 = 走 preview）。
  final Set<int> pages;

  /// 只看这一 P。
  final int page;
}

/// 多 P 视频的分 P 选择：多选 + 全选 / 清空，选完批量加入任务。
class _PagePickerDialog extends StatefulWidget {
  const _PagePickerDialog({required this.media});

  final ParsedMedia media;

  @override
  State<_PagePickerDialog> createState() => _PagePickerDialogState();
}

class _PagePickerDialogState extends State<_PagePickerDialog> {
  final Set<int> _picked = <int>{};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pages = widget.media.info.pages;
    final all = _picked.length == pages.length;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(child: Text(l10n.tr('download.pickPageTitle'))),
          TextButton(
            onPressed: () => setState(() {
              if (all) {
                _picked.clear();
              } else {
                _picked
                  ..clear()
                  ..addAll(pages.map((page) => page.page));
              }
            }),
            child: Text(
              l10n.tr(all ? 'download.pageClear' : 'download.pageAll'),
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      // ⚠️ 用 ListView.builder 逐行建：几百 P 的视频若一次全建，手机上会卡。
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: ListView.builder(
          itemCount: pages.length,
          itemBuilder: (context, index) {
            final page = pages[index];
            return CheckboxListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              controlAffinity: ListTileControlAffinity.leading,
              value: _picked.contains(page.page),
              onChanged: (_) => setState(() {
                if (!_picked.remove(page.page)) _picked.add(page.page);
              }),
              title: Text(
                page.part.isEmpty ? 'P${page.page}' : page.part,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                page.durationSec > 0
                    ? 'P${page.page} · ${formatDuration(page.durationSec)}'
                    : 'P${page.page}',
                style: const TextStyle(fontSize: 11, color: kTextFaint),
              ),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.tr('common.cancel')),
        ),
        if (_picked.length == 1)
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              _PagePick.preview(_picked.first),
            ),
            child: Text(l10n.tr('download.pagePreview')),
          ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.of(context).pop(_PagePick.enqueue(_picked)),
          child: Text(
            l10n.tr('download.pageEnqueue', {'count': '${_picked.length}'}),
          ),
        ),
      ],
    );
  }
}
