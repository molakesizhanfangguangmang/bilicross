import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/downloader.dart';
import '../core/models.dart';
import 'widgets.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.tasks.isEmpty) {
          return const PageFrame(
            title: '下载任务',
            child: EmptyState(
              icon: Icons.inbox_outlined,
              title: '暂无任务',
              message: '队列会区分等待、下载、合并、完成与失败状态。中断的任务在下次启动时按断点续传继续。',
            ),
          );
        }
        return PageFrame(
          title: '下载任务',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '并发 ${state.settings.maxParallelTasks} · 队列${state.queueRunning ? '运行中' : '空闲'}',
                  style: const TextStyle(color: Color(0xff6d716f), fontSize: 12),
                ),
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
      task.audioPath.isNotEmpty && hasUsableFile(task.videoPath) && hasUsableFile(task.audioPath);

  int get _tone => switch (task.stage) {
        TaskStage.done => 1,
        TaskStage.failed => 3,
        TaskStage.pending => 2,
        _ => 0,
      };

  @override
  Widget build(BuildContext context) {
    final running = task.stage == TaskStage.downloading || task.stage == TaskStage.muxing;
    return SectionCard(
      title: task.title,
      trailing: StateChip(text: task.stage.label, tone: _tone),
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
            label: '进度',
            value: '${formatBytes(task.receivedBytes)}'
                '${task.totalBytes > 0 ? ' / ${formatBytes(task.totalBytes)}' : ''}',
          ),
          InfoLine(label: '通道', value: task.channel.isEmpty ? '未记录' : task.channel),
          InfoLine(
            label: '分 P',
            value: task.page > 1 ? '第 ${task.page} P · cid ${task.cid}' : 'cid ${task.cid}',
          ),
          InfoLine(label: '引擎', value: task.engine == 'dart' ? 'Dart 内置' : task.engine),
          if (task.message.isNotEmpty) InfoLine(label: '状态', value: task.message),
          InfoLine(label: '输出', value: task.outputPath),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: running ? null : () => state.retryTask(task.id),
                child: const Text('重试'),
              ),
              if (!task.merged && _canMerge)
                OutlinedButton(
                  onPressed: running ? null : () => state.retryMerge(task.id),
                  child: const Text('重试合并'),
                ),
              if (task.stage == TaskStage.failed ||
                  (task.stage == TaskStage.done && !task.merged))
                OutlinedButton(
                  onPressed: running ? null : () => _cleanup(context, state, task),
                  child: const Text('清理残留'),
                ),
              OutlinedButton(
                onPressed: running ? null : () => state.removeTask(task.id),
                child: const Text('移除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 删掉这个任务留下的成品与分片，并把任务从列表里去掉。
  Future<void> _cleanup(
    BuildContext context,
    AppState state,
    DownloadTask task,
  ) async {
    final removed = await state.cleanupTask(task.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(removed > 0 ? '已清理 $removed 个文件' : '没有可清理的文件'),
      ),
    );
  }
}
