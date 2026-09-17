import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
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
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final media = state.parsed;
        if (media != null) {
          _rememberSelection(media);
        }
        return PageFrame(
          title: '新建下载',
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
                      decoration: const InputDecoration(
                        labelText: '视频、番剧或分 P 地址',
                        hintText: 'https://www.bilibili.com/video/BV... 或 b23.tv 短链',
                        prefixIcon: Icon(Icons.link),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: state.busy ? null : () => _parse(state, _controller.text),
                    icon: const Icon(Icons.search),
                    label: const Text('解析'),
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
                const EmptyState(
                  icon: Icons.video_library_outlined,
                  title: '等待解析',
                  message: '解析后会列出分 P、视频流与音频流，再选择要下载的组合。',
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
    final videoIndex = (_videoIndex ?? 0).clamp(-1, media.videos.length - 1);
    final audioIndex = (_audioIndex ?? (media.audios.isEmpty ? -1 : media.audios.length - 1))
        .clamp(-1, media.audios.length - 1);
    final canStart = videoIndex >= 0 || audioIndex >= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: media.info.title.isEmpty ? '解析结果' : media.info.title,
          trailing: StateChip(text: media.channel),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InfoLine(
                label: '标识',
                value:
                    '${media.info.bvid.isEmpty ? 'av${media.info.aid}' : media.info.bvid} · cid ${media.page.cid}',
              ),
              if (media.info.owner.isNotEmpty)
                InfoLine(label: 'UP 主', value: media.info.owner),
              InfoLine(label: '分 P', value: '${media.page.page} / ${media.info.pages.length} · ${media.page.part}'),
              InfoLine(label: '时长', value: formatDuration(media.durationSec)),
              if (media.page.epId > 0) InfoLine(label: 'ep', value: '${media.page.epId}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: '视频流',
          child: Column(
            children: [
              ChoiceTile(
                selected: videoIndex < 0,
                onTap: () => setState(() => _videoIndex = -1),
                title: '不下载视频（只保存音频）',
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
          title: '音频流',
          child: media.audios.isEmpty
              ? const Text('该通道没有单独音频流，只能保存视频。')
              : Column(
                  children: [
                    ChoiceTile(
                      selected: audioIndex < 0,
                      onTap: () => setState(() => _audioIndex = -1),
                      title: '不下载音频（只保存视频）',
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
                      ? '加入任务（${videoIndex >= 0 && audioIndex >= 0 ? '视频 + 音频' : videoIndex >= 0 ? '只有视频' : '只有音频'}）'
                      : '至少要选一条轨道',
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
                label: const Text('立即开始下载'),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          startNow ? '已加入任务队列，开始下载' : '已加入任务队列，去「任务」页点开始任务',
        ),
      ),
    );
  }
}
