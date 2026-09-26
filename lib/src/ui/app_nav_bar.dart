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

/// 带阻尼的弹簧进度曲线。
///
/// 输出 = 线性主项 `t` + 指数衰减的正弦偏移，从 0 平滑起步、稳定到 1。
/// 全程 C1 连续，没有分段衔接处的速度跳变。
class _SpringCurve extends Curve {
  const _SpringCurve({
    required this.overshoot,
    required this.damping,
    required this.cycles,
  });

  /// 冲过头的幅度（相对单格）。
  final double overshoot;

  /// 阻尼系数，越小衰减越慢、q 弹越久。
  final double damping;

  /// 振荡的额外回摆次数。
  final double cycles;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // 正弦频率按「回摆次数」定；(1 - t) 保证终点精确回到 1、无跳变。
    final phase = 2 * math.pi * cycles * t;
    final envelope = math.exp(-damping * t);
    final wobble = overshoot * envelope * math.sin(phase) * (1 - t);
    return t + wobble;
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

  late Animation<double> _position;

  int _fromIndex = 0;
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
    final distance =
        (target - _fromIndex).abs().clamp(1, widget.items.length - 1);
    final gap = DateTime.now().difference(_lastTap).inMilliseconds;
    _lastTap = DateTime.now();
    final fast = gap > 0 && gap < 240;

    final start = _fromIndex.toDouble();
    final end = target.toDouble();
    // 过冲幅度：距离越远、连点越快越大。
    final overshoot = 0.32 * distance * (fast ? 1.4 : 1.0);
    // 回摆次数：距离 + 连点加成；阻尼越小越持久。
    final cycles = (distance + (fast ? 1.5 : 0.5)).toDouble();
    final damping = fast ? 3.0 : 4.2;

    _position = Tween(
      begin: start,
      end: end,
    ).chain(
      CurveTween(
        curve: _SpringCurve(
          overshoot: overshoot,
          damping: damping,
          cycles: cycles,
        ),
      ),
    ).animate(_controller);

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
                animation: _position,
                builder: (context, _) {
                  final p = _position.value;
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
