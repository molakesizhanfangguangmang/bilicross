import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';

/// 任务列表按状态分成的三栏。
enum TaskTab { waiting, running, done }

/// 任务列表是否用懒加载（SliverList.builder 只构建屏幕内的卡片）。
///
/// 懒加载在长列表（200+ 条）下明显更省内存与构建时间，是这次卡顿的主修项；
/// 但它同时改变了滚动容器（CustomScrollView 取代 SingleChildScrollView），
/// 万一在某些环境出现滚动异常，把这里改成 false 即可退回旧行为 ——
/// 三栏、固定头、按栏按钮、合集分组这些改动不受影响，仍全部保留。
const bool kTasksLazyList = true;

/// 任务页：顶部固定头（状态 + 当前栏按钮）+ 三栏 Tab + 懒加载列表。
///
/// 之前的问题：PageFrame 是 SingleChildScrollView，216 条任务会一口气全部
/// 构建，条数越多越卡；按钮也在底部，内容多时要点很久。
/// 现在改成 CustomScrollView + SliverList.builder 懒加载，头和按钮用 Sliver
/// 固定在顶部，滚动时始终可见可点。
class TasksPage extends StatefulWidget {
  const TasksPage({required this.state, super.key});

  final AppState state;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  TaskTab _tab = TaskTab.waiting;

  bool _isWaiting(DownloadTask task) =>
      task.stage == TaskStage.pending ||
      task.stage == TaskStage.failed ||
      task.stage == TaskStage.stopped;

  bool _isRunning(DownloadTask task) =>
      task.stage == TaskStage.resolving ||
      task.stage == TaskStage.downloading ||
      task.stage == TaskStage.muxing ||
      task.stage == TaskStage.paused;

  /// 按合集分组：同一 batchId 的任务聚在一起，合集行显示在块顶。
  /// 没有清单信息的旧任务（batchId 为空）保持原顺序，不打散。
  List<List<DownloadTask>> _grouped(List<DownloadTask> tasks) {
    final groups = <String, List<DownloadTask>>{};
    final order = <String>[];
    final noBatch = <DownloadTask>[];

    for (final task in tasks) {
      final batchId = task.batchId;
      if (batchId.isEmpty) {
        noBatch.add(task);
        continue;
      }
      if (!groups.containsKey(batchId)) {
        groups[batchId] = <DownloadTask>[];
        order.add(batchId);
      }
      groups[batchId]!.add(task);
    }

    return <List<DownloadTask>>[
      for (final batchId in order) groups[batchId]!,
      // 没批次信息的旧任务按「单集一组」处理，保持原来的顺序。
      for (final task in noBatch) <DownloadTask>[task],
    ];
  }

  List<DownloadTask> _filter(List<DownloadTask> tasks) {
    switch (_tab) {
      case TaskTab.waiting:
        return tasks.where(_isWaiting).toList();
      case TaskTab.running:
        return tasks.where(_isRunning).toList();
      case TaskTab.done:
        return tasks.where((t) => t.stage == TaskStage.done).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final all = state.tasks;
        final visible = _filter(all);
        final groups = _grouped(visible);

        final waitingCount = all.where(_isWaiting).length;
        final runningCount = all.where(_isRunning).length;
        final doneCount = all.where((t) => t.stage == TaskStage.done).length;

        final buttons = _actionsFor(context, state, visible);

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: CustomScrollView(
                slivers: <Widget>[
                  // 头部固定：标题 + 状态行 + Tab + 按钮都在这里，滚动不动。
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            l10n.tr('tasks.title'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${l10n.tr('tasks.parallel', {'count': '${state.settings.maxParallelTasks}'})}'
                            ' · ${state.queueRunning ? l10n.tr('tasks.queueRunning') : l10n.tr('tasks.queueIdle')}'
                            ' · ${l10n.tr('tasks.pending', {'count': '${state.pendingCount}'})}',
                            style: const TextStyle(
                              color: Color(0xff6d716f),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          SegmentedButton<TaskTab>(
                            segments: <ButtonSegment<TaskTab>>[
                              ButtonSegment(
                                value: TaskTab.waiting,
                                label: Text(l10n.tr('tasks.tabWaiting', {
                                  'count': '$waitingCount',
                                })),
                                icon: const Icon(Icons.schedule, size: 16),
                              ),
                              ButtonSegment(
                                value: TaskTab.running,
                                label: Text(l10n.tr('tasks.tabRunning', {
                                  'count': '$runningCount',
                                })),
                                icon: const Icon(Icons.download, size: 16),
                              ),
                              ButtonSegment(
                                value: TaskTab.done,
                                label: Text(l10n.tr('tasks.tabDone', {
                                  'count': '$doneCount',
                                })),
                                icon: const Icon(Icons.done_all, size: 16),
                              ),
                            ],
                            selected: {_tab},
                            onSelectionChanged: (selection) =>
                                setState(() => _tab = selection.first),
                          ),
                          const SizedBox(height: 10),
                          if (buttons.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: buttons,
                            ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                  // 列表本体。
                  if (visible.isEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverToBoxAdapter(
                        child: EmptyState(
                          icon: Icons.inbox_outlined,
                          title: l10n.tr('tasks.emptyTitle'),
                          message: l10n.tr('tasks.emptyHint'),
                        ),
                      ),
                    )
                  else if (kTasksLazyList)
                    // 懒加载：只构建屏幕内的卡片（默认）。
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                      sliver: SliverList.builder(
                        itemCount: groups.length,
                        itemBuilder: (context, groupIndex) =>
                            _GroupSection(state: state, tasks: groups[groupIndex]),
                      ),
                    )
                  else
                    // 回滚路径：一次性全部构建（懒加载出问题时可切回来）。
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, groupIndex) =>
                              _GroupSection(state: state, tasks: groups[groupIndex]),
                          childCount: groups.length,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 当前栏可用的批量按钮。
  List<Widget> _actionsFor(
    BuildContext context,
    AppState state,
    List<DownloadTask> visible,
  ) {
    final l10n = AppLocalizations.of(context);
    switch (_tab) {
      case TaskTab.waiting:
        final canStart = visible.any((t) => t.stage == TaskStage.pending);
        final canStop = visible.any(
          (t) => t.stage == TaskStage.pending || t.stage == TaskStage.failed,
        );
        return <Widget>[
          FilledButton.icon(
            onPressed:
                state.queueRunning || !canStart ? null : () => state.pumpQueue(),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.tr('tasks.startQueue')),
          ),
          if (canStop)
            OutlinedButton.icon(
              onPressed: () => _confirm(
                context,
                title: l10n.tr('tasks.stopAll'),
                message: l10n.tr('tasks.stopAllWaitingConfirm', {
                  'count': '${visible.length}',
                }),
                onConfirm: () => state.stopWaitingTasks(),
              ),
              icon: const Icon(Icons.block, size: 18),
              label: Text(l10n.tr('tasks.stopAll')),
            ),
        ];
      case TaskTab.running:
        final anyRunning = visible.any((t) => t.stage == TaskStage.downloading);
        return <Widget>[
          OutlinedButton.icon(
            onPressed: anyRunning ? () => state.pauseAllTasks() : null,
            icon: const Icon(Icons.pause, size: 18),
            label: Text(l10n.tr('tasks.pauseAll')),
          ),
          OutlinedButton.icon(
            onPressed: visible.isEmpty
                ? null
                : () => _confirm(
                      context,
                      title: l10n.tr('tasks.stopAll'),
                      message: l10n.tr('tasks.stopAllRunningConfirm'),
                      onConfirm: () => state.stopRunningTasks(),
                    ),
            icon: const Icon(Icons.block, size: 18),
            label: Text(l10n.tr('tasks.stopAll')),
          ),
        ];
      case TaskTab.done:
        return <Widget>[
          OutlinedButton.icon(
            onPressed: visible.isEmpty
                ? null
                : () => _confirm(
                      context,
                      title: l10n.tr('tasks.cleanDone'),
                      message: l10n.tr('tasks.cleanDoneConfirm', {
                        'count': '${visible.length}',
                      }),
                      onConfirm: () => state.removeDoneTasks(),
                    ),
            icon: const Icon(Icons.cleaning_services, size: 18),
            label: Text(l10n.tr('tasks.cleanDone')),
          ),
        ];
    }
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required VoidCallback onConfirm,
  }) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.tr('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(title),
          ),
        ],
      ),
    );
    if (confirmed == true) onConfirm();
  }
}

/// 一组任务：有清单信息的显示合集行（标题 + 进度），没信息的直接平铺卡片。
class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.state, required this.tasks});

  final AppState state;
  final List<DownloadTask> tasks;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final first = tasks.first;
    final hasBatch = first.batchId.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hasBatch) ...<Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: const Color(0xffeef2f0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.video_library_outlined,
                    size: 16,
                    color: Color(0xff6d716f),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      first.seasonTitle.isEmpty
                          ? l10n.tr('manifest.untitled')
                          : first.seasonTitle,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    l10n.tr('tasks.groupProgress', {
                      'done':
                          '${tasks.where((t) => t.stage == TaskStage.done).length}',
                      'total': '${tasks.length}',
                    }),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff6d716f),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final task in tasks)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TaskCard(state: state, task: task),
            ),
        ],
      ),
    );
  }
}
