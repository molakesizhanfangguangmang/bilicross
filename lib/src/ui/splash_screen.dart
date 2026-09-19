import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/splash_config.dart';

/// 启动时的自定义开屏：铺满显示用户选的图，停留指定秒数后淡出。
///
/// 只在配置开启且图存在时使用；否则 [main] 直接进主界面，不走这里。
/// 停留结束后调 [onDone]，由上层切到主界面。
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.image,
    required this.seconds,
    required this.onDone,
  });

  /// 用户选的图。已经复制进数据目录，这里是那个文件。
  final File image;

  /// 停留秒数，已被 [clampSplashSeconds] 收进合法区间。
  final double seconds;

  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  /// 淡出动画时长；停留时间之外单独算，保证总时长符合用户设定。
  static const Duration _fadeOut = Duration(milliseconds: 320);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final hold = Duration(
      milliseconds: (clampSplashSeconds(widget.seconds) * 1000).round(),
    );
    _timer = Timer(hold, () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 铺满：cover 语义。图比窗口大就裁切，比窗口小就放大，始终不留边。
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedSwitcher(
        duration: _fadeOut,
        child: SizedBox.expand(
          child: Image.file(
            widget.image,
            fit: BoxFit.cover,
            // 解码按窗口尺寸裁：用户可能给到 4K 大图，全尺寸解码很占内存。
            cacheWidth: _decodeWidth(context),
            errorBuilder: (context, error, stack) => const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// 按屏幕物理宽度限制解码尺寸；拿不到时交给 Flutter 自己决定。
  int? _decodeWidth(BuildContext context) {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final width = MediaQuery.maybeSizeOf(context)?.width;
    if (width == null || width <= 0) return null;
    return (width * ratio).round();
  }
}
