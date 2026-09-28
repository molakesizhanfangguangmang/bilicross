import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一组导航目标的最小描述：图标 + 标签。
class NavItem {
  const NavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 底部导航：悬浮胶囊 + 弹性指示块。
///
/// 胶囊四周留白、浮在页面之上。指示块弹性滑动，**可越出胶囊边缘**
/// （左右最多 [NavBouncePreset.wall]，上下按撞击深度鼓出），
/// 撞到限位时按 [NavBouncePreset.squash] 压扁再弹回。
/// 幅度被限位截住时改用更高频率体现力度，所以「弹得猛」不会因为限位变软。
///
/// ⚠️ 指示块会越出胶囊，**外层不能裁剪**，且要预留上下余量（见 [_bleed]）。
Widget buildAppNavBar({
  required String style,
  required int selectedIndex,
  required List<NavItem> items,
  required ValueChanged<int> onSelect,
}) {
  return _CapsuleNavBar(
    selectedIndex: selectedIndex,
    items: items,
    onSelect: onSelect,
    preset: NavBouncePreset.of(style),
  );
}

/// 指示块动画预设。
class NavBouncePreset {
  const NavBouncePreset({
    required this.overshootBase,
    required this.damping,
    required this.period,
    required this.squash,
    required this.wall,
    required this.bleed,
  });

  /// 基础过冲幅度，单位是「格宽的比例」。
  final double overshootBase;

  /// 阻尼：越小回摆越持久。
  final double damping;

  /// 振荡频率系数：越大同样时间内回摆次数越多。
  final double period;

  /// 撞墙时的压扁强度（0 = 不压扁）。
  final double squash;

  /// 左右允许越出胶囊内边缘的最大比例，相对指示块宽度。
  final double wall;

  /// 撞墙时纵向最多鼓出的比例（相对指示块高度的一半，0 = 不鼓出）。
  final double bleed;

  /// 左右越界上限：指示块宽度的 3/7。
  static const double maxWall = 3 / 7;

  /// 关：不过冲、不压扁、不越界，平滑直滑。
  static const NavBouncePreset off = NavBouncePreset(
    overshootBase: 0,
    damping: 12,
    period: 1,
    squash: 0,
    wall: 0,
    bleed: 0,
  );

  /// 强度由设置里的档位决定：standard / q1 / q2 / q3 / q4。
  static NavBouncePreset of(String style) => switch (style) {
        // 轻弹：不越界、不压扁。
        'q1' => const NavBouncePreset(
            overshootBase: 0.16,
            damping: 10,
            period: 1.6,
            squash: 0,
            wall: 0,
            bleed: 0,
          ),
        // 弹墙：越界到上限，轻微压扁 + 轻微鼓出。
        'q2' => const NavBouncePreset(
            overshootBase: 0.30,
            damping: 8.5,
            period: 2.0,
            squash: 0.12,
            wall: maxWall,
            bleed: 0.5,
          ),
        // 弹墙·强：幅度更大、频率更高、压扁与鼓出都更明显。
        'q3' => const NavBouncePreset(
            overshootBase: 0.48,
            damping: 7.0,
            period: 2.4,
            squash: 0.22,
            wall: maxWall,
            bleed: 0.85,
          ),
        // 弹墙·频：幅度与 q3 相同，靠更高频率体现力度。
        'q4' => const NavBouncePreset(
            overshootBase: 0.48,
            damping: 6.2,
            period: 3.6,
            squash: 0.22,
            wall: maxWall,
            bleed: 0.85,
          ),
        _ => off,
      };
}

/// 弹性进度曲线：前半段快速逼近终点，只在终点附近过冲并衰减回摆。
class _SpringCurve extends Curve {
  const _SpringCurve({
    required this.overshoot,
    required this.damping,
    required this.period,
  });

  final double overshoot;
  final double damping;
  final double period;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final phase = math.pi * 2 * (t - 1) * period;
    final decay = math.pow(2, -damping * t).toDouble();
    final base = 1 + overshoot * math.sin(phase) * decay;
    return base.clamp(0.0, 1.0 + overshoot);
  }
}

class _CapsuleNavBar extends StatefulWidget {
  const _CapsuleNavBar({
    required this.selectedIndex,
    required this.items,
    required this.onSelect,
    required this.preset,
  });

  final int selectedIndex;
  final List<NavItem> items;
  final ValueChanged<int> onSelect;
  final NavBouncePreset preset;

  @override
  State<_CapsuleNavBar> createState() => _CapsuleNavBarState();
}

class _CapsuleNavBarState extends State<_CapsuleNavBar>
    with SingleTickerProviderStateMixin {
  /// 胶囊高度；圆角取一半即胶囊形。
  static const double _capsuleHeight = 72;

  /// 指示块高度：只包住图标。垂直居中于胶囊，与图标中心对齐。
  static const double _pillHeight = 36;

  /// 图标上边距：让图标中心落在胶囊中心（即指示块中心）。
  static const double _iconTop = 24;

  /// 胶囊左右留白。
  static const double _sideMargin = 14;

  /// 胶囊悬空高度（距屏幕底边）。
  static const double _bottomGap = 10;

  /// 指示块上下鼓出胶囊时，外层预留的余量（不裁切）。
  static const double _bleedRoom = 10;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  late Animation<double> _position;

  int _fromIndex = 0;
  DateTime _lastTap = DateTime.now();

  double _cellWidth = 0;
  double _indicatorWidth = 0;

  @override
  void initState() {
    super.initState();
    _fromIndex = widget.selectedIndex;
    _position = AlwaysStoppedAnimation(_fromIndex.toDouble());
  }

  @override
  void didUpdateWidget(_CapsuleNavBar oldWidget) {
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
    final preset = widget.preset;
    final distance =
        (target - _fromIndex).abs().clamp(1, widget.items.length - 1);
    final gap = DateTime.now().difference(_lastTap).inMilliseconds;
    _lastTap = DateTime.now();
    final fast = gap > 0 && gap < 240;

    final start = _fromIndex.toDouble();
    final end = target.toDouble();

    var period = preset.period;
    var overshoot =
        preset.overshootBase * (1 + 0.25 * distance) * (fast ? 1.4 : 1.0);

    // 撞到左右限位时：截断幅度，并用更高频率补回力度。
    final room = _roomFor(target);
    if (room != null && _cellWidth > 0 && overshoot * _cellWidth > room) {
      final ratio = overshoot * _cellWidth / math.max(room, 1);
      overshoot = room / _cellWidth;
      period *= 1 + (ratio - 1).clamp(0.0, 1.5) * 0.6;
    }

    if (preset.overshootBase <= 0 || overshoot <= 0) {
      _position = Tween(begin: start, end: end)
          .chain(CurveTween(curve: Curves.easeOutCubic))
          .animate(_controller);
    } else {
      _position = Tween(begin: start, end: end)
          .chain(
            CurveTween(
              curve: _SpringCurve(
                overshoot: overshoot,
                damping: preset.damping,
                period: period,
              ),
            ),
          )
          .animate(_controller);
    }

    _fromIndex = target;
    _controller.forward(from: 0);
  }

  /// 目标格允许中心越出的像素数；中间格返回 null（不限）。
  double? _roomFor(int target) {
    if (_cellWidth <= 0 || _indicatorWidth <= 0) return null;
    final half = _indicatorWidth / 2;
    final slack = widget.preset.wall * _indicatorWidth;
    if (target <= 0) {
      return math.max(_cellWidth / 2 - (half - slack), 0);
    }
    if (target >= widget.items.length - 1) {
      final totalWidth = _cellWidth * widget.items.length;
      final cellCenter = totalWidth - _cellWidth / 2;
      return math.max((totalWidth - half + slack) - cellCenter, 0);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final barTheme = Theme.of(context).navigationBarTheme;
    // 跟随「上下栏不透明度」：主题色带 alpha 时胶囊跟着透。
    final capsuleColor =
        barTheme.backgroundColor ?? scheme.surfaceContainerHigh;
    final radius = _capsuleHeight / 2;

    return SafeArea(
      top: false,
      child: Padding(
        // 上下各留 _bleedRoom：指示块鼓出胶囊时不被父级裁掉。
        padding: const EdgeInsets.symmetric(vertical: _bleedRoom),
        child: Padding(
          // 胶囊左右留白 + 底部悬空。
          padding: const EdgeInsets.only(
            left: _sideMargin,
            right: _sideMargin,
            bottom: _bottomGap,
          ),
          child: SizedBox(
            height: _capsuleHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // 胶囊本体：不裁切，指示块可以越出去。
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: capsuleColor,
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.10),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final count = widget.items.length;
                    final cellWidth = constraints.maxWidth / count;
                    final indicatorWidth = math.min(64.0, cellWidth * 0.74);
                    _cellWidth = cellWidth;
                    _indicatorWidth = indicatorWidth;

                    return AnimatedBuilder(
                      animation: _position,
                      builder: (context, _) {
                      final raw = _position.value;
                      final half = indicatorWidth / 2;
                      final slack = widget.preset.wall * indicatorWidth;
                      final rawCenter = raw * cellWidth + cellWidth / 2;

                      // 左右撞墙：中心不越出「内边缘再外扩 slack」。
                      final minCenter = half - slack;
                      final maxCenter =
                          constraints.maxWidth - half + slack;
                      final center =
                          rawCenter.clamp(minCenter, maxCenter).toDouble();
                      final hit = (rawCenter - center).abs();

                      final squash = widget.preset.squash;
                      final depth = squash <= 0 || half <= 0
                          ? 0.0
                          : (hit / half).clamp(0.0, 1.0) * squash;
                      // 撞墙时上下鼓出：横向压扁的形变由纵向补偿。
                      final bulge = depth * widget.preset.bleed;
                      final align = rawCenter > center
                          ? Alignment.centerRight
                          : Alignment.centerLeft;

                        // 指示块垂直居中于胶囊，中心与图标中心对齐。
                        final pillTop = (_capsuleHeight - _pillHeight) / 2;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            Positioned(
                              left: center - half,
                              top: pillTop,
                              width: indicatorWidth,
                              height: _pillHeight,
                              child: Align(
                                alignment: align,
                                child: Transform.scale(
                                  scaleX: 1 - depth,
                                  scaleY: 1 + bulge,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      borderRadius: BorderRadius.circular(
                                        _pillHeight / 2,
                                      ),
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                            ),
                            Row(
                              children: <Widget>[
                                for (var i = 0; i < count; i++)
                                  Expanded(
                                    child: _NavCell(
                                      icon: widget.items[i].icon,
                                      label: widget.items[i].label,
                                      iconTop: _iconTop,
                                      // 图标颜色跟着指示块位置走：滑到哪哪变白，
                                      // 中途不跳色。
                                      onIndicator: (raw - i).abs() < 0.5,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  const _NavCell({
    required this.icon,
    required this.label,
    required this.iconTop,
    required this.onIndicator,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final double iconTop;
  final bool onIndicator;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          SizedBox(height: iconTop),
          Icon(
            icon,
            size: 24,
            color: onIndicator ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: onIndicator ? FontWeight.w600 : FontWeight.w400,
              color: onIndicator ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
