import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 斜向平铺的水印层。
///
/// 铺在应用内容**之上**，并用 [IgnorePointer] 屏蔽指针 —— 只影响观感、不影响操作。
/// 放在内容之上而不是内容之下，是因为内容不透明处会把下层水印完全盖住；
/// 屏蔽指针这点很重要：覆盖层一旦截获命中测试，整个界面会点不动。
///
/// 水印文字**固定中文**，不跟随界面语言：它是内部测试包的标记。
class Watermark extends StatelessWidget {
  const Watermark({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // 水印是静态图案，包一层 RepaintBoundary 避免跟着上层动画反复重绘。
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _WatermarkPainter(text: text),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter({required this.text});

  final String text;

  /// 平铺步距：密了显脏，疏了容易被裁掉。
  static const double _stepX = 220;
  static const double _stepY = 150;

  /// 倾斜角度（弧度），约 -26°。
  static const double _angle = -0.45;

  /// 水印透明度：再高就会影响阅读。
  static const double _opacity = 0.05;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 14,
          color: Colors.black.withValues(alpha: _opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // 旋转之后原来的矩形已经盖不满，按对角线长度扩展绘制范围。
    final diagonal = math.sqrt(
      size.width * size.width + size.height * size.height,
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(_angle);
    canvas.translate(-diagonal / 2, -diagonal / 2);
    for (double y = 0; y < diagonal; y += _stepY) {
      for (double x = 0; x < diagonal; x += _stepX) {
        painter.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WatermarkPainter oldDelegate) => oldDelegate.text != text;
}
