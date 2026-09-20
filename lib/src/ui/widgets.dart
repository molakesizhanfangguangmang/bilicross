import 'package:flutter/material.dart';
import '../i18n/app_localizations.dart';
import '../core/downloader.dart';
import '../core/models.dart';
import '../app_state.dart';

class PageFrame extends StatelessWidget {
  const PageFrame({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class InfoLine extends StatelessWidget {
  const InfoLine({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(color: Color(0xff6d716f))),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 240),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffd9dedb)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42, color: const Color(0xff65716c)),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单选行。不使用 Radio/RadioListTile：其 groupValue/onChanged 在新版 Flutter 已废弃，
/// 而 CI 的 analyze 会把弃用提示当作问题。
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    required this.selected,
    required this.title,
    required this.onTap,
    super.key,
  });

  final bool selected;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? Theme.of(context).colorScheme.primary : const Color(0xff9aa3a0),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
          ],
        ),
      ),
    );
  }
}

class StateChip extends StatelessWidget {
  const StateChip({required this.text, this.tone = 0, super.key});

  /// 0 中性，1 正常，2 警示，3 失败。
  final String text;
  final int tone;

  @override
  Widget build(BuildContext context) {
    final (background, border) = switch (tone) {
      1 => (const Color(0xffe6eee9), const Color(0xff8fb3a4)),
      2 => (const Color(0xfff4efe2), const Color(0xffcbb78a)),
      3 => (const Color(0xfff3e6e4), const Color(0xffc9a19c)),
      _ => (const Color(0xffeeefee), const Color(0xffc9cecc)),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

class TaskCard extends StatelessWidget {
  const TaskCard({required this.state, required this.task, super.key});

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
