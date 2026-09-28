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
///
/// ⚠️ 指示块会越出胶囊，**外层不能裁剪**，且要预留上下余量（见 `_bleedRoom`）。
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
///
/// 两个维度**完全解耦**：
/// - [overshoot] 决定冲出去多远（「轻 / 重」）；
/// - [period] 决定 t∈[0,1] 内回摆几次（「低频 / 高频」）。
///
/// 所以四档可以覆盖 2×2：利落（轻+快）、柔和（轻+慢）、
/// Q 弹（重+快）、慵懒（重+慢）。
class NavBouncePreset {
  const NavBouncePreset({
    required this.overshoot,
    required this.period,
    required this.squash,
    required this.wall,
    required this.bleed,
  });

  /// 目标过冲量：冲过终点多远，单位是「格宽的比例」。
  final double overshoot;

  /// 振荡频率：动画时长内回摆的完整周期数。
  final double period;

  /// 撞墙时的压扁强度（0 = 不压扁）。
  final double squash;

  /// 左右允许越出胶囊内边缘的最大比例，相对指示块宽度。
  final double wall;

  /// 撞墙时纵向最多鼓出的比例（0 = 不鼓出）。
  final double bleed;

  /// 左右越界上限：指示块宽度的 3/7。
  static const double maxWall = 3 / 7;

  /// 关：不过冲、不压扁、不越界，平滑直滑。
  static const NavBouncePreset off = NavBouncePreset(
    overshoot: 0,
    period: 1,
    squash: 0,
    wall: 0,
    bleed: 0,
  );

  /// 强度由设置里的档位决定：standard / q1 / q2 / q3 / q4。
  static NavBouncePreset of(String style) => switch (style) {
        // 利落：轻幅度 + 高频。冲得少、颤得快，干脆。
        'q1' => const NavBouncePreset(
            overshoot: 0.10,
            period: 2.4,
            squash: 0.10,
            wall: maxWall * 0.5,
            bleed: 0.5,
          ),
        // 柔和：轻幅度 + 低频。轻轻晃一下。
        'q2' => const NavBouncePreset(
            overshoot: 0.10,
            period: 1.3,
            squash: 0.10,
            wall: maxWall * 0.5,
            bleed: 0.5,
          ),
        // Q 弹（默认）：重幅度 + 高频。抖得猛，最「Q」。
        'q3' => const NavBouncePreset(
            overshoot: 0.28,
            period: 2.4,
            squash: 0.22,
            wall: maxWall,
            bleed: 0.85,
          ),
        // 慵懒：重幅度 + 低频。大而慢的回摆。
        'q4' => const NavBouncePreset(
            overshoot: 0.28,
            period: 1.3,
            squash: 0.22,
            wall: maxWall,
            bleed: 0.85,
          ),
        _ => off,
      };
}

/// 欠阻尼弹簧阶跃响应，[0,1] 上的缓动曲线。
///
/// 形式 `y(t) = 1 - e^(-k·ω·t)·(cos(ω·t) + k·sin(ω·t))`，
/// 其中 `k = -ln(overshoot)/π`，`ω = 2π·period`。
///
/// 这个形式的两个参数**互不干扰**：
/// - `k` 只决定峰值高度（首次峰值恰为 `1 + overshoot`）；
/// - `ω` 只决定振荡快慢。
///
/// 并且严格 `y(0)=0`、`y(1)≈1`：起步单调向前，只在终点附近过冲回摆。
class _SpringCurve extends Curve {
  const _SpringCurve({required this.overshoot, required this.period});

  /// 目标过冲量（>0）。
  final double overshoot;

  /// 振荡频率（周期数）。
  final double period;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final target = overshoot.clamp(0.01, 0.8);
    final k = -math.log(target) / math.pi;
    final omega = math.pi * 2 * period;
    final decay = math.exp(-k * omega * t);
    final value =
        1 - decay * (math.cos(omega * t) + k * math.sin(omega * t));
    return value.clamp(0.0, 1.0 + target);
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

  /// 指示块高度：只包住图标。
  static const double _pillHeight = 36;

  /// 指示块顶部位置。**不垂直居中** —— 整体略偏上，
  /// 给下方文字腾出净空。
  static const double _pillTop = 12;

  /// 图标顶部位置：让图标在指示块内垂直居中。
  /// `_pillTop + (_pillHeight - 24) / 2 = 12 + 6 = 18`。
  static const double _iconTop = 18;

  /// 胶囊左右留白。
  static const double _sideMargin = 14;

  /// 胶囊悬空高度（距屏幕底边）。
  static const double _bottomGap = 10;

  /// 指示块上下鼓出胶囊时，外层预留的余量（不裁切）。
  static const double _bleedRoom = 10;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
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
    final gap = DateTime.now().difference(_lastTap).inMilliseconds;
    _lastTap = DateTime.now();
    final fast = gap > 0 && gap < 240;

    final start = _fromIndex.toDouble();
    final end = target.toDouble();

    var period = preset.period;
    var overshoot = preset.overshoot * (fast ? 1.35 : 1.0);

    // 撞到左右限位时：截断幅度，并用更高频率补回力度。
    final room = _roomFor(target);
    if (room != null && _cellWidth > 0 && overshoot * _cellWidth > room) {
      final ratio = overshoot * _cellWidth / math.max(room, 1);
      overshoot = room / _cellWidth;
      period *= 1 + (ratio - 1).clamp(0.0, 1.5) * 0.6;
    }

    if (preset.overshoot <= 0 || overshoot <= 0) {
      _position = Tween(begin: start, end: end)
          .chain(CurveTween(curve: Curves.easeOutCubic))
          .animate(_controller);
    } else {
      _position = Tween(begin: start, end: end)
          .chain(
            CurveTween(
              curve: _SpringCurve(overshoot: overshoot, period: period),
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
                    final indicatorWidth = math.min(60.0, cellWidth * 0.72);
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
                        // 撞墙时纵向鼓出：横向压扁由纵向补偿。
                        final bulge = depth * widget.preset.bleed;
                        final align = rawCenter > center
                            ? Alignment.centerRight
                            : Alignment.centerLeft;

                        return Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            Positioned(
                              left: center - half,
                              top: _pillTop,
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
          // 间距 8 = 指示块比图标多探出的 6px + 2px 呼吸，
          // 文字落在指示块下沿之外，不被盖住。
          const SizedBox(height: 8),
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
