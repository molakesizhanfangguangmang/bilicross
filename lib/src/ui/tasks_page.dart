import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/downloader.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.tasks.isEmpty) {
          return PageFrame(
            title: l10n.tr('tasks.title'),
            child: EmptyState(
              icon: Icons.inbox_outlined,
              title: l10n.tr('tasks.emptyTitle'),
              message: l10n.tr('tasks.emptyHint'),
            ),
          );
        }
        return PageFrame(
          title: l10n.tr('tasks.title'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${l10n.tr('tasks.parallel', {
                            'count': '${state.settings.maxParallelTasks}',
                          })}'
                      ' · ${state.queueRunning ? l10n.tr('tasks.queueRunning') : l10n.tr('tasks.queueIdle')}'
                      ' · ${l10n.tr('tasks.pending', {'count': '${state.pendingCount}'})}',
                      style: const TextStyle(color: Color(0xff6d716f), fontSize: 12),
                    ),
                  ),
                  // 队列跑起来之后，新入队的任务会自己跟上，不用再点一次。
                  FilledButton.icon(
                    onPressed: state.queueRunning || !state.hasPending
                        ? null
                        : () => state.pumpQueue(),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      state.queueRunning
                          ? l10n.tr('tasks.queueRunning')
                          : l10n.tr('tasks.startQueue'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              for (final task in state.tasks) ...[
                _TaskCard(state: state, task: task),
                const SizedBox(height: 10),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.state, required this.task});

  final AppState state;
  final DownloadTask task;

  /// 分片都还在时允许单独重跑合并。
  bool get _canMerge =>
      !task.singleTrack &&
      task.audioPath.isNotEmpty &&
      hasUsableFile(task.videoPath) &&
      hasUsableFile(task.audioPath);

  int get _tone => switch (task.stage) {
        TaskStage.done => 1,
        TaskStage.failed => 3,
        TaskStage.stopped => 3,
        TaskStage.pending => 2,
        TaskStage.paused => 2,
        _ => 0,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final running = task.stage == TaskStage.downloading || task.stage == TaskStage.muxing;
    return SectionCard(
      title: task.title,
      trailing: StateChip(text: task.stage.label(l10n), tone: _tone),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (running || task.progress > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(
                minHeight: 3,
                value: task.stage == TaskStage.muxing ? null : task.progress,
              ),
            ),
          InfoLine(
            label: l10n.tr('tasks.progress'),
            value: '${formatBytes(task.receivedBytes)}'
                '${task.totalBytes > 0 ? ' / ${formatBytes(task.totalBytes)}' : ''}',
          ),
          InfoLine(
            label: l10n.tr('tasks.channel'),
            value: task.channel.isEmpty ? l10n.tr('tasks.notRecorded') : task.channel,
          ),
          InfoLine(
            label: l10n.tr('download.part'),
            value: task.page > 1
                ? l10n.tr('tasks.pagePart', {'page': '${task.page}', 'cid': '${task.cid}'})
                : l10n.tr('tasks.cidOnly', {'cid': '${task.cid}'}),
          ),
          InfoLine(
            label: l10n.tr('tasks.engine'),
            value: task.engine == 'dart' ? l10n.tr('tasks.dartEngine') : task.engine,
          ),
          if (task.message.isNotEmpty)
            InfoLine(label: l10n.tr('tasks.status'), value: task.message),
          InfoLine(label: l10n.tr('tasks.output'), value: task.outputPath),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              // 下载中可以暂停（分片留着，继续时按断点接）；合并中没有暂停点，只有强制结束。
              if (task.stage == TaskStage.downloading)
                OutlinedButton(
                  onPressed: () => state.pauseTask(task.id),
                  child: Text(l10n.tr('tasks.pause')),
                ),
              if (running)
                OutlinedButton(
                  onPressed: () => _stop(context, state, task),
                  child: Text(l10n.tr('tasks.forceStop')),
                ),
              if (task.stage == TaskStage.paused)
                OutlinedButton(
                  onPressed: () => state.resumeTask(task.id),
                  child: Text(l10n.tr('tasks.resume')),
                ),
              OutlinedButton(
                onPressed: running ? null : () => state.retryTask(task.id),
                child: Text(l10n.tr('tasks.retry')),
              ),
              if (!task.merged && _canMerge)
                OutlinedButton(
                  onPressed: running ? null : () => state.retryMerge(task.id),
                  child: Text(l10n.tr('tasks.retryMux')),
                ),
              if (task.stage == TaskStage.failed ||
                  task.stage == TaskStage.stopped ||
                  task.stage == TaskStage.paused ||
                  (task.stage == TaskStage.done && !task.merged && !task.singleTrack))
                OutlinedButton(
                  onPressed: running ? null : () => _cleanup(context, state, task),
                  child: Text(l10n.tr('tasks.cleanup')),
                ),
              OutlinedButton(
                onPressed: running ? null : () => state.removeTask(task.id),
                child: Text(l10n.tr('common.remove')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 强制结束会连分片一起删掉，删了就续不回来，所以先确认一次。
  Future<void> _stop(
    BuildContext context,
    AppState state,
    DownloadTask task,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tr('tasks.forceStop')),
        content: Text(
          '${l10n.tr('tasks.forceStopConfirm', {'title': task.title})}'
          '${l10n.tr('tasks.forceStopWarning')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.tr('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.tr('tasks.forceStop')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    state.stopTask(task.id);
  }

  /// 删掉这个任务留下的成品与分片，并把任务从列表里去掉。
  Future<void> _cleanup(
    BuildContext context,
    AppState state,
    DownloadTask task,
  ) async {
    final l10n = AppLocalizations.of(context);
    final removed = await state.cleanupTask(task.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed > 0
              ? l10n.tr('tasks.cleanedFiles', {'count': '$removed'})
              : l10n.tr('tasks.nothingToClean'),
        ),
      ),
    );
  }
}
