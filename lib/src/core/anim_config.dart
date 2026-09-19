import 'package:flutter/animation.dart';

/// 展开动画的可调参数。
///
/// 这些参数平时不暴露，长按「高级设置」入口才解锁（见 [AppSettings.animTuningUnlocked]）。

/// 动画时长范围与默认值（毫秒）。
///
/// 默认 300ms + 最缓曲线（`sine`）是本项目的统一观感基准：
/// 短促但不突兀，展开过程仍看得清。可调项只在解锁后才会被用户改动。
const int kAnimMinDurationMs = 200;
const int kAnimMaxDurationMs = 800;
const int kAnimDefaultDurationMs = 300;

/// 曲线档位。键是存进设置的字符串，值是实际曲线。
///
/// 用 `easeOut` 族：起始速度等于幂次，档位从缓到急依次为 sine < quad < cubic < quart < expo。
/// 默认取最缓的 `sine`。
const String kAnimDefaultCurve = 'sine';
const Map<String, Curve> kAnimCurves = <String, Curve>{
  'sine': Curves.easeOutSine,
  'quad': Curves.easeOutQuad,
  'cubic': Curves.easeOutCubic,
  'quart': Curves.easeOutQuart,
  'expo': Curves.easeOutExpo,
};

/// 展开形式：矩形展开 / 纯淡入 / 缩放。
const String kAnimDefaultStyle = 'expand';
const List<String> kAnimStyles = <String>['expand', 'fade', 'scale'];

/// 把时长夹到允许范围。
int clampAnimDuration(int value) {
  if (value < kAnimMinDurationMs) return kAnimMinDurationMs;
  if (value > kAnimMaxDurationMs) return kAnimMaxDurationMs;
  return value;
}

/// 非法或缺失的曲线档位回落到默认值。
String normalizeAnimCurve(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return kAnimCurves.containsKey(value) ? value : kAnimDefaultCurve;
}

/// 非法或缺失的展开形式回落到默认值。
String normalizeAnimStyle(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return kAnimStyles.contains(value) ? value : kAnimDefaultStyle;
}

/// 档位名换成实际曲线。
Curve curveOf(String name) => kAnimCurves[normalizeAnimCurve(name)]!;
