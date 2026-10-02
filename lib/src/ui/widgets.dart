import 'dart:ui';

import 'package:flutter/material.dart';
import '../i18n/app_localizations.dart';
import '../core/announcement.dart';
import '../core/background_config.dart';
import '../core/models.dart';
import '../app_state.dart';
import './palette.dart';

/// 「非卡片面」的兜底底色 —— `EmptyState` 占位框、任务页分组头这类
/// **不是卡片**的面。
///
/// ⚠️ 卡片浓度（`cardTheme.color`）只作用于真卡片；这些面在默认态必须保持原样
/// （占位框零填充、分组头用 `kSurfaceTint`），所以默认是 `null`＝「沿用各处原本的
/// 默认外观」。只在「开了背景或卡片 < 100%」时才由 main.dart 塞进一个非空值。
/// ⚠️ 这是**唯一来源**，别再在别处硬编码这些面的底色。
class PanelFill extends ThemeExtension<PanelFill> {
  const PanelFill(
    this.color, {
    this.cardFrostMode = kCardFrostOff,
    this.hasBackground = false,
    this.uiOpacity = kUiMaxOpacity,
  });

  final Color? color;
  final String cardFrostMode;
  final bool hasBackground;
  final double uiOpacity;

  @override
  PanelFill copyWith({
    Color? color,
    String? cardFrostMode,
    bool? hasBackground,
    double? uiOpacity,
  }) =>
      PanelFill(
        color ?? this.color,
        cardFrostMode: cardFrostMode ?? this.cardFrostMode,
        hasBackground: hasBackground ?? this.hasBackground,
        uiOpacity: uiOpacity ?? this.uiOpacity,
      );

  @override
  PanelFill lerp(covariant PanelFill? other, double t) {
    if (other == null) return this;
    return PanelFill(
      Color.lerp(color, other.color, t),
      cardFrostMode: other.cardFrostMode,
      hasBackground: other.hasBackground,
      uiOpacity: other.uiOpacity,
    );
  }
}

/// 取「非卡片面」的兜底底色；`null` ＝ 保持该处原本的默认外观。
Color? panelColor(BuildContext context) =>
    Theme.of(context).extension<PanelFill>()?.color;

/// 磨砂玻璃的统一判定：要不要套磨砂、是不是「透背景」模式。
///
/// `overBackground` 只在「开了背景图」时成立 —— 没背景图时透背景模式退化成普通卡片。
/// `alpha` 是磨砂底色实际用的不透明度，跟随「卡片不透明度」滑杆。
({bool enabled, bool overBackground, double alpha}) _frostState(BuildContext context) {
  final fill = Theme.of(context).extension<PanelFill>();
  final mode = fill?.cardFrostMode ?? kCardFrostOff;
  final hasBackground = fill?.hasBackground ?? false;
  final uiOpacity = clampUiOpacity(fill?.uiOpacity ?? kUiMaxOpacity);
  final frosted = mode == kCardFrosted;
  // 开关开 = 透背景磨砂；没背景图时退化成普通磨砂（用更实一点的底色）。
  final overBackground = frosted && hasBackground;
  // 透背景时给底色降一点浓度，让背后的画面更容易透出来；下限 0.16 防文字糊掉。
  final alpha = overBackground
      ? (uiOpacity * 0.38).clamp(0.16, 0.38)
      : (uiOpacity * 0.42).clamp(0.18, 0.42);
  return (enabled: frosted, overBackground: overBackground, alpha: alpha);
}

/// 带磨砂能力的普通卡片壳（无标题栏），供「高级设置」「关于」这类入口和
/// [CollapsibleSection] 使用。
///
/// 未开磨砂时等价于普通 [Card]（继承 `cardTheme` 的 elevation 0 + 描边）；
/// 开了磨砂时给半透明底 + 白边 + 阴影 + 背景模糊，与 [SectionCard] 同规格。
class FrostCard extends StatelessWidget {
  const FrostCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final frost = _frostState(context);
    if (!frost.enabled) {
      return Card(clipBehavior: Clip.antiAlias, child: child);
    }
    final scheme = Theme.of(context).colorScheme;
    final card = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest
          .withValues(alpha: frost.alpha),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.55),
            width: 1,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: child,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: RepaintBoundary(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: card,
        ),
      ),
    );
  }
}

/// 给「非卡片面」（下载页地址行、任务页顶部固定条）套一层兜底底色，圆角与卡片一致。
///
/// ⚠️ `panelColor` 为 `null`（默认态）时**只留内边距、不加底色** —— 几何与旧版逐像素
/// 一致，零回归。要在别处给非卡片面上底，一律走这里，别再各写各的。
/// ⚠️ `radius` 默认 8（浮在页面里的面板）；贴着 AppBar 的通栏（任务页顶部固定条）
/// 传 0 —— 上边贴边还带圆角会像被裁掉的卡片。
class PanelBox extends StatelessWidget {
  const PanelBox({
    required this.child,
    this.padding,
    this.radius = 8,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final color = panelColor(context);
    final frost = _frostState(context);
    final useFrost = frost.enabled;
    final scheme = Theme.of(context).colorScheme;

    // 默认态（无磨砂且无底色）保持 decoration 为 null，几何与旧版逐像素一致。
    if (!useFrost && color == null) {
      return Container(padding: padding, child: child);
    }
    final inner = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: useFrost
            ? scheme.surfaceContainerHighest
                .withValues(alpha: frost.alpha)
            : color,
        borderRadius: BorderRadius.circular(radius),
        border: useFrost
            ? Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1,
              )
            : null,
        boxShadow: useFrost
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: child,
    );
    if (!useFrost) {
      return inner;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: RepaintBoundary(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: inner,
        ),
      ),
    );
  }
}

/// 手机端的宽度断点：窄于这个宽度按手机布局处理。
///
/// ⚠️ 有些改动**只在手机端生效**（用户 2026-09-20 明确要求）—— 桌面窗口宽，
/// 标题大一号、按钮铺开都不占地方，没必要跟着一起缩。
const double kCompactWidth = 600;

bool isCompactLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width < kCompactWidth;

/// 页面标题样式。手机端降一号：默认的 24px 在手机上太占地方。
TextStyle pageTitleStyle(BuildContext context) {
  final base =
      Theme.of(context).textTheme.headlineSmall ?? const TextStyle(fontSize: 24);
  if (!isCompactLayout(context)) return base;
  return base.copyWith(fontSize: 20);
}

/// 手机端的紧凑按钮样式：矮一点、字小一点，一行能多放几个。
ButtonStyle compactActionStyle() => OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12),
    );

/// 页面外壳：内容居中、宽度封顶 980，自带滚动。
///
/// ⚠️ **不再渲染页面标题** —— 标题统一由顶部 AppBar 显示（见 main.dart）。
/// 以前这里是「AppBar 显示应用名 + 内容区再显示一次页名」，手机上等于
/// 两条标题栏叠着，白占一整行的高度。
class PageFrame extends StatelessWidget {
  const PageFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: child,
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
    // 透背景磨砂只在有背景图时生效；没背景图就退化成普通卡片（完全无磨砂效果）。
    final frost = _frostState(context);
    final useFrost = frost.enabled;
    final content = Padding(
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
    );
    if (!useFrost) {
      return Card(child: content);
    }
    final scheme = Theme.of(context).colorScheme;
    final card = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      // 磨砂要在白底/纯色底下也看得出：用更实的底色 + 白边 + 阴影兜住轮廓，
      // 单靠半透明底色会在白底上几乎看不见。
      color: scheme.surfaceContainerHighest
          .withValues(alpha: frost.alpha),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.55),
            width: 1,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: content,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: RepaintBoundary(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: card,
        ),
      ),
    );
  }
}

/// 可折叠的设置分组：组头一行（标题 + 当前值摘要 + 展开箭头），点一下开合。
///
/// ⚠️ 展开状态由调用方持有 —— 不要写进设置对象，否则点一下展开就会被
/// 当成「有未保存的改动」。
class CollapsibleSection extends StatelessWidget {
  const CollapsibleSection({
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.child,
    super.key,
  });

  final String title;

  /// 收起时也看得见的当前值，排在标题右侧。
  final String summary;

  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FrostCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: kTextSubtle,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: child,
            ),
        ],
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
            child: Text(label, style: const TextStyle(color: kTextMuted)),
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

  Widget _buildContent(BuildContext context) {
    final frost = _frostState(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 240),
      decoration: BoxDecoration(
        color: frost.enabled
            ? scheme.surfaceContainerHighest
                .withValues(alpha: frost.alpha)
            : panelColor(context),
        border: frost.enabled
            ? Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1)
            : Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(8),
        boxShadow: frost.enabled
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42, color: kTextSubtle),
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

  @override
  Widget build(BuildContext context) {
    if (!_frostState(context).enabled) return _buildContent(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: RepaintBoundary(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: _buildContent(context),
        ),
      ),
    );
  }
}

/// 单选行。不使用 Radio/RadioListTile：其 groupValue/onChanged 在新版 Flutter 已废弃，
/// 而 CI 的 analyze 会把弃用提示当作问题。
/// 公告里的一张图。
///
/// ⚠️ 公告是**单向下发**的内容，图挂了一张不该在弹窗里留个红叉或撑出一片空白 ——
/// 加载失败就整块收起。加载完成（或失败）时回调一次 [onSettled]，公告弹窗靠它
/// 重算「正文到底要不要滑到底」（图片晚于正文到位，会改变可滚高度）。
class AnnouncementImage extends StatefulWidget {
  const AnnouncementImage({
    required this.path,
    this.maxHeight = 220,
    this.radius = 8,
    this.onSettled,
    super.key,
  });

  final String path;
  final double maxHeight;
  final double radius;
  final VoidCallback? onSettled;

  @override
  State<AnnouncementImage> createState() => _AnnouncementImageState();
}

class _AnnouncementImageState extends State<AnnouncementImage> {
  bool _settled = false;

  void _settle() {
    if (_settled) return;
    _settled = true;
    final callback = widget.onSettled;
    if (callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = announcementMediaUrl(widget.path);
    if (url.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: Image.network(
          url,
          width: double.infinity,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) {
              _settle();
              return child;
            }
            return const SizedBox(
              height: 120,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            _settle();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    required this.selected,
    required this.title,
    required this.onTap,
    this.image = '',
    super.key,
  });

  final bool selected;
  final String title;

  /// 选项配图（相对路径，空串＝纯文字）。放在文字上方。
  final String image;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 8),
                child: AnnouncementImage(path: image, maxHeight: 160),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? Theme.of(context).colorScheme.primary : kTextFaint,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
              ],
            ),
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
      1 => (kBrandTint, kBrandSoft),
      2 => (kWarningSurface, kWarningBorder),
      3 => (kDangerSurface, kDangerBorder),
      _ => (kSurfaceNeutral, kBorderStrong),
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

  /// 分片都还在时允许单独重跑合并。判断走 [AppState.canRetryMerge]（缓存过的），
  /// 这里在 build 路径上，不能同步 stat。
  bool get _canMerge => state.canRetryMerge(task);

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
              // 等待中的任务：「开始」只下这一条，不动等待栏里其他待下的。
              // 其余状态仍是「重试」—— 同一按钮位按状态换名，不让两个按钮做同一件事。
              if (task.stage == TaskStage.pending)
                FilledButton.icon(
                  onPressed:
                      state.queueRunning ? null : () => state.startTask(task.id),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(l10n.tr('tasks.start')),
                )
              else
                OutlinedButton(
                  onPressed: running ? null : () => state.retryTask(task.id),
                  child: Text(l10n.tr('tasks.retry')),
                ),
              // running 时短路：分片还在写，判断既无意义又正撞上通知最密的时段。
              if (!running && !task.merged && _canMerge)
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
