import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../core/anim_config.dart';

/// 从某个控件的位置展开到整页的过渡路由。
///
/// 等价于已停止维护的 `animations` 包里的 `OpenContainer`，但只保留需要的部分：
/// 起始矩形取被点控件在屏幕上的实际位置，终止矩形是整页。
///
/// 实现：用 [Positioned] 把目标页放进插值出来的矩形里，外层 [ClipRRect] 裁掉
/// 超出的部分；目标页始终按最终尺寸布局，只用裁剪表现由小到大，
/// 避免布局随矩形反复重排导致文字来回折行。
class ExpandPageRoute<T> extends PageRouteBuilder<T> {
  ExpandPageRoute({
    required this.sourceRect,
    required this.builder,
    this.duration = const Duration(milliseconds: kAnimDefaultDurationMs),
    this.curveName,
    this.style = kAnimDefaultStyle,
    super.settings,
  }) : super(
          transitionDuration: duration,
          // 收回比推出略快：收回是"取消"动作，拖久了显得黏。
          reverseTransitionDuration: const Duration(milliseconds: 360),
          // 过渡期间下层页面继续渲染，配合 barrierColor 做出遮罩效果。
          opaque: false,
          barrierColor: Colors.black54,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        );

  /// 被点控件在全局坐标系里的矩形。拿不到时退化成整页淡入。
  final Rect? sourceRect;

  final Duration duration;

  /// 展开曲线档位（见 [kAnimCurves]）。传 null 时按平台取默认值。
  final String? curveName;

  /// 展开形式（见 [kAnimStyles]）。
  final String style;

  final WidgetBuilder builder;

  /// 内容开始淡入的进度。
  ///
  /// 取值偏小（0.25）是刻意的：让内容和矩形展开**同步**长出来，
  /// 而不是等框子撑开大半才"啪"地出现。太早会露出小框里折行的文字，
  /// 太晚则显得内容与展开是两件事。
  static const double _contentFadeStart = 0.25;

  /// 起始圆角，跟列表卡片的圆角保持一致。
  static const double _sourceRadius = 8;

  /// 内容起始缩放。
  ///
  /// 平行外扩本身是四条边同速移动，观感偏"机械"；给内容叠一点点缩放
  /// （0.97 → 1.0）能补出"浮起来"的层次。缩放露出的边缘由外层 Material
  /// 的 surface 色兜住，所以看不出破绽。
  static const double _contentScaleFrom = 0.97;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curve = curveName == null
        ? _expandCurve
        : curveOf(curveName!);
    // 正向：前快后慢。
    //
    // 反向不能直接把正向曲线填进 reverseCurve：CurvedAnimation 反向时执行的是
    // reverseCurve.transform(parentValue)，而 parentValue 从 1 降到 0，
    // 直接填会让收回变成"前慢后快"。flipped 把曲线镜像过来，方向才对：
    // flipped(easeOutQuart) 约 34% 的时间走完 80% 路程。
    final curved = CurvedAnimation(
      parent: animation,
      curve: curve,
      reverseCurve: Curves.easeOutQuart.flipped,
    );

    // 纯淡入形式：不做矩形展开。
    if (style == 'fade') {
      return FadeTransition(opacity: curved, child: child);
    }

    final from = sourceRect;
    if (from == null || from.isEmpty) {
      return FadeTransition(opacity: curved, child: child);
    }
    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        // 动画走到两端时交回真实布局：过渡期的定位是"画"出来的，
        // 命中测试范围与视觉不一致，留着包装会让控件点不动。
        final progress = animation.value;
        if (progress >= 0.999 || progress <= 0.001) {
          return child;
        }
        final t = curved.value;
        final pageSize = MediaQuery.sizeOf(context);
        final full = Offset.zero & pageSize;
        // 缩放形式：以卡片中心为基准放大到整页；矩形形式：四条边平行外扩。
        final rect = style == 'scale'
            ? _scaleRect(from, full, t)
            : (Rect.lerp(from, full, t) ?? full);
        final radius = _lerp(_sourceRadius, 0, t);
        final contentOpacity =
            ((progress - _contentFadeStart) / (1 - _contentFadeStart))
                .clamp(0.0, 1.0);
        final contentScale = _lerp(_contentScaleFrom, 1.0, t);
        return ClipRect(
          child: Stack(
            children: <Widget>[
              Positioned.fromRect(
                rect: rect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    child: Opacity(
                      opacity: contentOpacity,
                      child: Transform.scale(
                        scale: contentScale,
                        child: _fixedSize(child, pageSize),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 以卡片中心为不动点，把卡片尺寸按 t 放大到整页尺寸。
  static Rect _scaleRect(Rect from, Rect full, double t) {
    final center = Offset.lerp(from.center, full.center, t) ?? full.center;
    final width = _lerp(from.width, full.width, t);
    final height = _lerp(from.height, full.height, t);
    return Rect.fromCenter(center: center, width: width, height: height);
  }

  /// 让页面始终按最终尺寸布局，不受外层矩形变化影响。
  Widget _fixedSize(Widget child, Size pageSize) {
    return SizedBox(
      width: pageSize.width,
      height: pageSize.height,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: pageSize.width,
        maxWidth: pageSize.width,
        minHeight: pageSize.height,
        maxHeight: pageSize.height,
        child: child,
      ),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// 取某个 context 对应控件在屏幕上的矩形；拿不到返回 null。
Rect? globalRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final origin = box.localToGlobal(Offset.zero);
  return origin & box.size;
}

/// 展开动画的进度曲线，按平台取值。
///
/// `easeOut` 族的**起始速度等于它的幂次**：`easeOutExpo` 起步最猛（约 5），
/// `easeOutCubic` 是 3，`easeOutQuad` 是 2。手机上用 Expo/Cubic 时展开的第一下
/// 冲得太快，换成 Quad 把起步速度降到 2/3，整体也更缓
/// （走完 80% 距离从约 42% 时间变为约 55% 时间）。
/// 桌面端屏幕大、观感不同，维持原曲线不动。
Curve get _expandCurve =>
    defaultTargetPlatform == TargetPlatform.android
        ? Curves.easeOutQuad
        : Curves.easeOutExpo;
