import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';

/// 任务列表按状态分成的三栏。
enum TaskTab { waiting, running, done }

/// 任务列表是否用懒加载（逐行构建，屏幕外的行不建）。
///
/// 前提是行列表**已经摊平**（见 `_rows`）：以前按组交给 SliverList、
/// 组内再用 Column 铺卡片，itemCount 只有 1，懒加载等于没做。
/// 万一懒加载在某些环境出问题，把这里改成 false 即退回一次性构建 ——
/// 固定头、三栏、按栏按钮、合集/段分组都不受影响。
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

  /// 把分组结构**摊平成一维行列表**，交给 `SliverList.builder` 逐行构建。
  ///
  /// ⚠️ 必须摊平。`_grouped` 会把同一个批次的几百条聚成**一个**组，
  /// 若让 SliverList 的每一项是一个组、组内再用 Column 把卡片全铺出来，
  /// `itemCount` 就只有 1 —— 懒加载等于没做，几百张卡照样一次全建，
  /// 这就是之前进任务页卡顿的原因。
  List<_ListRow> _rows(List<DownloadTask> tasks) {
    final rows = <_ListRow>[];
    for (final group in _grouped(tasks)) {
      final hasBatch = group.first.batchId.isNotEmpty;
      if (hasBatch) rows.add(_GroupRow(group));
      // 有批次信息才分段；没有的（旧任务 / 未分段合集）直接平铺。
      final sections = hasBatch ? _bySection(group) : <List<DownloadTask>>[group];
      for (final section in sections) {
        final titled = hasBatch && section.first.sectionTitle.isNotEmpty;
        if (titled) rows.add(_SectionRow(section));
        for (final task in section) {
          rows.add(_TaskRow(task, indented: titled));
        }
      }
    }
    return rows;
  }

  /// 批次内按段分组，保持原顺序。
  static List<List<DownloadTask>> _bySection(List<DownloadTask> tasks) {
    final order = <int>[];
    final groups = <int, List<DownloadTask>>{};
    for (final task in tasks) {
      if (!groups.containsKey(task.sectionId)) {
        groups[task.sectionId] = <DownloadTask>[];
        order.add(task.sectionId);
      }
      groups[task.sectionId]!.add(task);
    }
    return <List<DownloadTask>>[for (final key in order) groups[key]!];
  }

  List<DownloadTask> _filter(List<DownloadTask> tasks) {    switch (_tab) {
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
        final rows = _rows(visible);

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 头部**真正**固定：放在滚动容器外面，怎么滚都不动。
                  // ⚠️ 之前把它当成 CustomScrollView 里的 SliverToBoxAdapter，
                  // 那是跟着内容一起滚的 —— 注释写着「滚动不动」，实际会滚走。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
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
                        if (buttons.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: buttons,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: CustomScrollView(
                      slivers: <Widget>[
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
                          // 懒加载：逐行构建，屏幕外的行不建（默认）。
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                            sliver: SliverList.builder(
                              itemCount: rows.length,
                              itemBuilder: (context, index) =>
                                  _buildRow(context, state, rows[index]),
                            ),
                          )
                        else
                          // 回滚路径：一次性把全部行建出来（懒加载出问题时可切回来）。
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  for (final row in rows)
                                    _buildRow(context, state, row),
                                ],
                              ),
                            ),
                          ),
                      ],
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

  /// 一行一个组件：合集头 / 段头 / 任务卡。
  Widget _buildRow(BuildContext context, AppState state, _ListRow row) {
    switch (row) {
      case _GroupRow(:final tasks):
        return _GroupHeader(tasks: tasks);
      case _SectionRow(:final tasks):
        return _SectionHeader(state: state, tasks: tasks);
      case _TaskRow(:final task):
        return Padding(
          padding: EdgeInsets.only(
            bottom: 10,
            left: row.indented ? 14 : 0,
          ),
          child: TaskCard(state: state, task: task),
        );
    }
  }

  /// 当前栏可用的批量按钮。
  List<Widget> _actionsFor(
    BuildContext context,
    AppState state,
    List<DownloadTask> visible,
  ) {
    final l10n = AppLocalizations.of(context);
    final actions = <Widget>[];
    switch (_tab) {
      case TaskTab.waiting:
        final canStart = visible.any((t) => t.stage == TaskStage.pending);
        final canStop = visible.any(
          (t) => t.stage == TaskStage.pending || t.stage == TaskStage.failed,
        );
        actions.add(
          FilledButton.icon(
            onPressed:
                state.queueRunning || !canStart ? null : () => state.pumpQueue(),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.tr('tasks.startQueue')),
          ),
        );
        if (canStop) {
          actions.add(
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
          );
        }
      case TaskTab.running:
        final anyRunning = visible.any((t) => t.stage == TaskStage.downloading);
        actions.add(
          OutlinedButton.icon(
            onPressed: anyRunning ? () => state.pauseAllTasks() : null,
            icon: const Icon(Icons.pause, size: 18),
            label: Text(l10n.tr('tasks.pauseAll')),
          ),
        );
        actions.add(
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
        );
      case TaskTab.done:
        actions.add(
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
        );
    }

    // 下面两个与当前栏无关，三栏都放一份 —— 否则为了清东西还得先切栏。
    actions.add(
      OutlinedButton.icon(
        onPressed: state.tasks.isEmpty
            ? null
            : () => _cleanupResidue(context, state),
        icon: const Icon(Icons.auto_delete_outlined, size: 18),
        label: Text(l10n.tr('tasks.cleanResidue')),
      ),
    );
    actions.add(
      OutlinedButton.icon(
        // 有任务在跑就先别清：文件还在写，删了也是白删。
        onPressed: state.tasks.isEmpty || state.activeTaskCount > 0
            ? null
            : () => _clearAll(context, state),
        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
        label: Text(l10n.tr('tasks.clearAll')),
      ),
    );
    return actions;
  }

  /// 清理残留：删掉没下成/被终止的任务留下的分片与半成品。
  /// 已下载完成的成品不动 —— 那是用户要的东西。
  Future<void> _cleanupResidue(BuildContext context, AppState state) async {
    final l10n = AppLocalizations.of(context);
    final removable = state.tasks
        .where((t) =>
            t.stage != TaskStage.done &&
            t.stage != TaskStage.resolving &&
            t.stage != TaskStage.downloading &&
            t.stage != TaskStage.muxing)
        .length;
    final removed = await state.cleanupResidue();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.tr('tasks.cleanResidueDone', {
            'count': '$removed',
            'tasks': '$removable',
          }),
        ),
      ),
    );
  }

  /// 清空任务列表。弹窗里给两个选择：只删记录，或连残留文件一起删。
  /// **两种都不动已下载完成的成品。**
  Future<void> _clearAll(BuildContext context, AppState state) async {
    final l10n = AppLocalizations.of(context);
    final total = state.tasks.length;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tr('tasks.clearAll')),
        content: Text(
          l10n.tr('tasks.clearAllConfirm', {'count': '$total'}),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('cancel'),
            child: Text(l10n.tr('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('records'),
            child: Text(l10n.tr('tasks.clearRecordsOnly')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('files'),
            child: Text(l10n.tr('tasks.clearWithFiles')),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;
    final removed = await state.clearAllTasks(removeFiles: choice == 'files');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          choice == 'files'
              ? l10n.tr('tasks.clearAllDoneWithFiles', {'count': '$removed'})
              : l10n.tr('tasks.clearAllDone'),
        ),
      ),
    );
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

/// 任务列表里的一行。摊平成一维之后交给 `SliverList.builder` 逐行构建，
/// 屏幕外的行不会建 —— 这是任务页不卡的关键。
sealed class _ListRow {
  const _ListRow();
}

/// 合集头：标题 + 总进度。
class _GroupRow extends _ListRow {
  const _GroupRow(this.tasks);

  final List<DownloadTask> tasks;
}

/// 段头：段名 + 段进度 + 暂停 / 终止 / 重试。
class _SectionRow extends _ListRow {
  const _SectionRow(this.tasks);

  final List<DownloadTask> tasks;
}

/// 一集一张卡。[indented] 表示它属于某个有名字的段，缩进一级。
class _TaskRow extends _ListRow {
  const _TaskRow(this.task, {required this.indented});

  final DownloadTask task;
  final bool indented;
}

/// 合集头：有清单信息的组显示它（标题 + 进度），没信息的组不显示。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.tasks});

  final List<DownloadTask> tasks;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final first = tasks.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
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
              style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 段行：段名 + 进度 + 暂停 / 终止 / 重试。
///
/// 三个按钮都只作用于这一段 —— 这就是「单独下某段」真正需要的东西，
/// 不必为此再做一个「只下这段」的按钮。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.state, required this.tasks});

  final AppState state;
  final List<DownloadTask> tasks;

  static bool _running(TaskStage stage) =>
      stage == TaskStage.resolving ||
      stage == TaskStage.downloading ||
      stage == TaskStage.muxing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ids = <String>[for (final task in tasks) task.id];
    final done = tasks.where((t) => t.stage == TaskStage.done).length;
    final running = tasks.where((t) => _running(t.stage)).length;
    final paused = tasks.where((t) => t.stage == TaskStage.paused).length;
    final waiting = tasks
        .where((t) =>
            t.stage == TaskStage.pending ||
            t.stage == TaskStage.failed ||
            t.stage == TaskStage.stopped)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.folder_outlined,
            size: 15,
            color: Color(0xff6d716f),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              tasks.first.sectionTitle.isEmpty
                  ? l10n.tr('manifest.untitledSection')
                  : tasks.first.sectionTitle,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            l10n.tr('tasks.groupProgress', {
              'done': '$done',
              'total': '${tasks.length}',
            }),
            style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
          ),
          _SectionAction(
            icon: Icons.pause,
            tooltip: l10n.tr('tasks.sectionPause'),
            onPressed: running + paused > 0
                ? () => state.pauseTasks(ids)
                : null,
          ),
          _SectionAction(
            icon: Icons.stop,
            tooltip: l10n.tr('tasks.sectionStop'),
            onPressed: running + paused + waiting > 0
                ? () => state.stopTasks(ids)
                : null,
          ),
          _SectionAction(
            icon: Icons.refresh,
            tooltip: l10n.tr('tasks.sectionRetry'),
            onPressed: waiting > 0 ? () => state.retryTasks(ids) : null,
          ),
        ],
      ),
    );
  }
}

/// 段行上的小图标按钮：撑满的 IconButton 会让一行塞不下三个。
class _SectionAction extends StatelessWidget {
  const _SectionAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: const Color(0xff6d716f),
      ),
    );
  }
}
