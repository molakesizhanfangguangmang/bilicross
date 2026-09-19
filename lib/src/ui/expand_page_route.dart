import 'package:flutter/material.dart';

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
    this.duration = const Duration(milliseconds: 420),
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

  final WidgetBuilder builder;

  /// 内容开始淡入的进度：前半程只做位移与放大，避免文字在小框里折行。
  static const double _contentFadeStart = 0.45;

  /// 起始圆角，跟列表卡片的圆角保持一致。
  static const double _sourceRadius = 8;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final from = sourceRect;
    if (from == null || from.isEmpty) {
      return FadeTransition(opacity: animation, child: child);
    }
    // 正向：前快后慢（easeOutExpo）。
    //
    // 反向不能直接把正向曲线填进 reverseCurve：CurvedAnimation 反向时执行的是
    // reverseCurve.transform(parentValue)，而 parentValue 从 1 降到 0，
    // 直接填会让收回变成"前慢后快"。flipped 把曲线镜像过来，方向才对：
    // flipped(easeOutQuart) 约 34% 的时间走完 80% 路程。
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutExpo,
      reverseCurve: Curves.easeOutQuart.flipped,
    );
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
        final rect = Rect.lerp(from, full, t) ?? full;
        final radius = _lerp(_sourceRadius, 0, t);
        final contentOpacity =
            ((progress - _contentFadeStart) / (1 - _contentFadeStart))
                .clamp(0.0, 1.0);
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
                      child: _fixedSize(child, pageSize),
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
