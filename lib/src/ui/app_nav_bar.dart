import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一组导航目标的最小描述：图标 + 标签。
class NavItem {
  const NavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 底部导航。按 [style] 二选一：
///
/// - `standard`：Material 3 [NavigationBar]，默认观感（零回归）。
/// - `q`：自绘底栏，选中指示块在 tab 间弹性滑动，到位后阻尼振荡 q 弹几次再停；
///   振荡次数与强度随「目标距离」「点按速度」变大。
Widget buildAppNavBar({
  required String style,
  required int selectedIndex,
  required List<NavItem> items,
  required ValueChanged<int> onSelect,
}) {
  if (style == 'q') {
    return _QBounceNavBar(
      selectedIndex: selectedIndex,
      items: items,
      onSelect: onSelect,
    );
  }
  return NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: onSelect,
    destinations: [
      for (final item in items)
        NavigationDestination(icon: Icon(item.icon), label: item.label),
    ],
  );
}

/// 阻尼振荡曲线：先到达峰值，再以指数衰减振荡，最终稳定到 1。
///
/// [bounces] 是「额外冲过终点」的次数；[damping] 越小衰减越慢、振荡越持久。
/// 值域 [0, 1]。
class _DampedOscillation extends Curve {
  const _DampedOscillation({required this.bounces, required this.damping});

  final int bounces;
  final double damping;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // 振荡总相位：第一次冲过去 + bounces 次额外回摆。
    final cycles = bounces + 0.5;
    final phase = 2 * math.pi * cycles * t;
    final envelope = math.exp(-damping * t);
    // 振幅归一化：t=0 时为 0，终点收敛到 1。
    final oscillation = math.sin(phase);
    final amplitude = 1 / math.sin(2 * math.pi * cycles);
    final raw = 1 + envelope * oscillation * amplitude;
    return raw.clamp(0.0, 1.4);
  }
}

/// 弹性指示块底栏：外观对齐 M3 底栏，只把指示块换成自绘的阻尼振荡滑动。
class _QBounceNavBar extends StatefulWidget {
  const _QBounceNavBar({
    required this.selectedIndex,
    required this.items,
    required this.onSelect,
  });

  final int selectedIndex;
  final List<NavItem> items;
  final ValueChanged<int> onSelect;

  @override
  State<_QBounceNavBar> createState() => _QBounceNavBarState();
}

class _QBounceNavBarState extends State<_QBounceNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  Animation<double>? _position;

  /// 动画起点（上一个停留的索引）。
  int _fromIndex = 0;

  /// 最近一次点击时间，用于把连点折算成更强的 q 弹。
  DateTime _lastTap = DateTime.now();

  @override
  void initState() {
    super.initState();
    _fromIndex = widget.selectedIndex;
    _position = AlwaysStoppedAnimation(_fromIndex.toDouble());
  }

  @override
  void didUpdateWidget(_QBounceNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _runTo(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _runTo(int target) {
    final distance = (target - _fromIndex).abs().clamp(1, widget.items.length - 1);
    final gap = DateTime.now().difference(_lastTap).inMilliseconds;
    _lastTap = DateTime.now();
    // 连点（240ms 内）视为「很快」，多 q 弹一次、衰减更慢。
    final fast = gap > 0 && gap < 240;
    final bounces = (distance + (fast ? 1 : 0)).clamp(1, 4);
    final damping = fast ? 3.2 : 4.6;

    final start = _fromIndex.toDouble();
    final end = target.toDouble();
    final dir = end >= start ? 1.0 : -1.0;
    final curve = _DampedOscillation(bounces: bounces, damping: damping);
    // 峰值 = 终点 + 方向 * 过冲幅度；幅度随距离与速度放大。
    final amplitude = 0.30 * distance * (fast ? 1.35 : 1.0);
    final peak = end + dir * amplitude;

    _position = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: start, end: peak)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 34,
      ),
      TweenSequenceItem(
        tween: Tween(begin: peak, end: end).chain(CurveTween(curve: curve)),
        weight: 66,
      ),
    ]).animate(_controller);

    _fromIndex = target;
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final barTheme = Theme.of(context).navigationBarTheme;
    final background = barTheme.backgroundColor ?? scheme.surfaceContainer;
    return Material(
      color: background,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final count = widget.items.length;
              final cellWidth = constraints.maxWidth / count;
              return AnimatedBuilder(
                animation: _position ?? const AlwaysStoppedAnimation(0.0),
                builder: (context, _) {
                  final p = _position!.value;
                  final centerX = p * cellWidth + cellWidth / 2;
                  return Stack(
                    children: [
                      Positioned(
                        left: centerX - _indicatorWidth / 2,
                        top: 8,
                        width: _indicatorWidth,
                        height: 32,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < count; i++)
                            Expanded(
                              child: _NavCell(
                                icon: widget.items[i].icon,
                                label: widget.items[i].label,
                                selected: i == widget.selectedIndex,
                                onTap: () => widget.onSelect(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  static const double _indicatorWidth = 64;
}

class _NavCell extends StatelessWidget {
  const _NavCell({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 24,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
