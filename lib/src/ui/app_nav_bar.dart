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

/// 弹性进度曲线（对齐 Flutter `Curves.elasticOut` 的形态）。
///
/// 前半段快速逼近终点，只在**终点附近**冲过头并快速衰减回弹；
/// 中途不回退，所以跨格不会出现「没到就折返」的粘滞感。
class _SpringCurve extends Curve {
  const _SpringCurve({
    required this.overshoot,
    required this.damping,
  });

  /// 冲过头的幅度（相对整段位移的比例）。
  final double overshoot;

  /// 阻尼系数：越大过冲越窄、越只发生在终点附近。
  final double damping;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // 与 Curves.elasticOut 同构：主项 + 指数衰减正弦过冲。
    // phase 在终点处让 sin=0，且衰减极快，保证只终点附近过冲、中途单调。
    final phase = math.pi * 2 * (t - 1);
    final decay = math.pow(2, -damping * t).toDouble();
    final oscillation = math.sin(phase);
    final base = 1 + overshoot * oscillation * decay;
    return base.clamp(0.0, 1.0 + overshoot);
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
    final overshoot = (0.18 + 0.10 * distance) * (fast ? 1.5 : 1.0);
    // 衰减越慢 q 弹越持久；连点快时更明显。
    final damping = fast ? 6.0 : 8.0;

    _position = Tween(
      begin: start,
      end: end,
    ).chain(
      CurveTween(
        curve: _SpringCurve(
          overshoot: overshoot,
          damping: damping,
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
                        top: 14,
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
