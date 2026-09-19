import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'season_manifest_view.dart';
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

  /// 清单里勾中的合集内序号（由 SeasonManifestView 回报）。
  Set<int> _selectedEpisodes = <int>{};

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
              if (state.busy)
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
    await state.parseAddress(value);
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
        // 这条视频属于某个合集时，把整部合集列出来 —— 数据就在 view 的响应里，
        // 不额外发请求。第 1 步只做只读展示，勾选在第 2 步接入。
        if (media.info.season != null) ...<Widget>[
          const SizedBox(height: 12),
          SectionCard(
            title: l10n.tr('manifest.title'),
            child: SeasonManifestView(
              manifest: media.info.season!,
              preflightOf: state.preflightOf,
              isPreflighting: state.isPreflighting,
              // 必须 setState：勾选状态放在父级（按钮要读它决定可用性与集数），
              // 不回写的话按钮会一直停在「已选 0 集」的灰色状态。
              onSelectionChanged: (pages) {
                setState(() => _selectedEpisodes = pages);
                // 勾选变了就补跑预检：只查选中的，取消勾选的会被清掉。
                unawaited(
                  state.preflightEpisodes(
                    manifest: media.info.season!,
                    pages: pages,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Builder(
              builder: (context) {
                final total = _selectedEpisodes.length;
                final ready = state.preflightReadyCount(_selectedEpisodes);
                final allReady = total > 0 && ready == total;
                return FilledButton.icon(
                  // 未预检完的集不给下载：按钮只在选中的集全部通过预检时可点。
                  onPressed: allReady
                      ? () =>
                          _enqueueManifest(context, state, media.info.season!)
                      : null,
                  icon: const Icon(Icons.playlist_add),
                  label: Text(
                    total == 0
                        ? l10n.tr('manifest.enqueueSelected', {'count': '0'})
                        : allReady
                            ? l10n.tr(
                                'manifest.enqueueSelected',
                                {'count': '$total'},
                              )
                            : l10n.tr('manifest.preflighting', {
                                'ready': '$ready',
                                'total': '$total',
                              }),
                  ),
                );
              },
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

  /// 清单批量入队：勾中的集交给 [AppState.enqueueEpisodes] 登记进队列。
  /// 全程不逐集弹窗，结束后统一弹一条「加入/跳过/重命名」统计。
  void _enqueueManifest(
    BuildContext context,
    AppState state,
    SeasonManifest manifest,
  ) {
    final outcome = state.enqueueEpisodes(
      manifest: manifest,
      selectedPages: _selectedEpisodes,
      engine: 'dart',
    );
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.tr('manifest.batchResult', {
            'enqueued': '${outcome.enqueued}',
            'skipped': '${outcome.skipped}',
            'renamed': '${outcome.renamed}',
          }),
        ),
      ),
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
