import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 把 Windows 系统标题栏染成应用主题色。
///
/// 走 DWM 的 `DWMWA_CAPTION_COLOR`（Windows 11 起支持）。只改标题栏颜色，
/// 不改窗口结构：拖动、贴边、双击最大化、关闭拦截这些系统行为原样保留。
///
/// 之所以不用「隐藏系统标题栏 + 自绘」那条路：实测 `setTitleBarStyle(hidden)`
/// 会打乱窗口坐标系，导致 Flutter 侧命中测试错位（界面里控件点不动）、
/// 关闭拦截也失效。改颜色没有这些问题。

/// 按窗口标题找到主窗口并给标题栏上色。
///
/// [r]/[g]/[b] 是 0-255 的分量。失败一律静默：找不到窗口、
/// 系统低于 Windows 11、API 不可用等情况都只是「标题栏保持默认色」，
/// 不该影响应用运行。
void applyCaptionColorByTitle(String windowTitle, int r, int g, int b) {
  if (!Platform.isWindows) return;
  if (windowTitle.isEmpty) return;

  final arena = Arena();
  try {
    final hwnd =
        FindWindow(null, windowTitle.toPcwstr(allocator: arena)).value;
    // HWND 是 extension type（implements Pointer），跟整数比较会报类型不匹配，
    // 按指针判空。
    if (hwnd == nullptr) return;
    // COLORREF 是 win32 的 extension type（implements int），不能直接当 FFI
    // 类型参数用，所以按底层的 32 位无符号整数分配；RGB 宏的返回值可直接赋给它。
    final color = arena<Uint32>()..value = RGB(r, g, b);
    DwmSetWindowAttribute(
      hwnd,
      DWMWA_CAPTION_COLOR,
      color.cast(),
      sizeOf<Uint32>(),
    );
  } on Object {
    // Windows 10 或更早版本不支持这个属性，忽略。
  } finally {
    arena.releaseAll();
  }
}
