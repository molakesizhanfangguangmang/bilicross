import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一组导航目标的最小描述：图标 + 标签。
class NavItem {
  const NavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 底部导航。按 [style] 四选一：
///
/// - `standard`：Material 3 [NavigationBar]，默认观感（零回归）。
/// - `q1` / `q2` / `q3`：自绘底栏，选中指示块弹性滑动、到位后阻尼振荡，
///   三档强度递增。
Widget buildAppNavBar({
  required String style,
  required int selectedIndex,
  required List<NavItem> items,
  required ValueChanged<int> onSelect,
}) {
  if (style == 'q1' || style == 'q2' || style == 'q3') {
    final intensity = switch (style) {
      'q1' => 1,
      'q2' => 2,
      _ => 3,
    };
    return _QBounceNavBar(
      selectedIndex: selectedIndex,
      items: items,
      onSelect: onSelect,
      intensity: intensity,
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
    required this.period,
  });

  /// 冲过头的幅度（相对整段位移的比例）。
  final double overshoot;

  /// 阻尼系数：越大过冲越窄、越只发生在终点附近。
  final double damping;

  /// 振荡周期系数：越大在相同时间里回摆次数越多。
  final double period;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // 与 Curves.elasticOut 同构：主项 + 指数衰减正弦过冲。
    // phase 在终点处让 sin=0，且衰减极快，保证只终点附近过冲、中途单调。
    final phase = math.pi * 2 * (t - 1) * period;
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
    required this.intensity,
  });

  final int selectedIndex;
  final List<NavItem> items;
  final ValueChanged<int> onSelect;
  final int intensity;

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
    // 三档基础过冲幅度：轻/中/重。
    final baseOvershoot = switch (widget.intensity) {
      1 => 0.16,
      2 => 0.28,
      _ => 0.42,
    };
    // 距离越远、连点越快越强。
    final overshoot =
        baseOvershoot * (1 + 0.25 * distance) * (fast ? 1.4 : 1.0);
    // 衰减：档越高回摆越明显（衰减稍慢），但都保持不拖沓。
    final damping = switch (widget.intensity) {
      1 => 10.0,
      2 => 8.5,
      _ => 7.0,
    };
    // 振荡速度：整体放慢。档越高回摆次数略多。
    final period = switch (widget.intensity) {
      1 => 1.6,
      2 => 2.0,
      _ => 2.4,
    };

    _position = Tween(
      begin: start,
      end: end,
    ).chain(
      CurveTween(
        curve: _SpringCurve(
          overshoot: overshoot,
          damping: damping,
          period: period,
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
