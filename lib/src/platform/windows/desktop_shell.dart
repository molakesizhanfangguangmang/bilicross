import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/log_store.dart';
import 'caption_color.dart';

/// 原生窗口的标题。
///
/// 必须与 `windows/runner/main.cpp` 里 `window.Create(L"...")` 的值一致
/// （CI 的 Apply icon and window title 步骤会把它设成同一串）。
/// 给标题栏上色时按这个标题用 `FindWindowW` 找窗口。
const String _kWindowTitle = '逸轨';

/// Windows 的窗口与托盘外壳。
///
/// 只在 Windows 调用（见 [isSupported] 与调用处的平台判断）：
/// 关闭按钮默认不退出，隐藏主窗口进托盘，下载继续跑；用户选了「关闭即退出」
/// 时先问应用一句「能不能退」（有任务在跑就要二次确认），允许退出才真正关掉，
/// 退出前先把托盘图标摘掉，不留孤儿图标。
///
/// 这里只做平台外壳：托盘与窗口的初始化、菜单与关闭拦截；业务动作全部由调用方
/// 以回调注入（显示窗口、打开下载目录、暂停全部、是否允许退出），
/// 不在这里碰 Cookie、下载或设置。
class DesktopShell with WindowListener, TrayListener {
  DesktopShell({
    required this.onShow,
    required this.onOpenFolder,
    required this.onPauseAll,
    required this.onConfirmQuit,
    required this.labels,
  });

  /// 托盘菜单与关闭确认的文案（跟随应用语言，由调用方给）。
  final DesktopShellLabels labels;

  final Future<void> Function() onShow;
  final Future<void> Function() onOpenFolder;
  final Future<void> Function() onPauseAll;

  /// 关闭窗口时（关闭即退出的模式）询问应用：**返回 true 才真的退出**。
  /// 应用在那里弹二次确认：有解析中/下载中/合并中的任务要说明会中断。
  final Future<bool> Function() onConfirmQuit;

  static const String menuShow = 'show';
  static const String menuFolder = 'folder';
  static const String menuPause = 'pause';
  static const String menuQuit = 'quit';

  static const String _iconAsset = 'packaging/windows/app_icon.ico';

  static bool get isSupported => Platform.isWindows;

  bool _closeToTray = true;
  bool _initialized = false;

  Future<void> initialize({required bool closeToTray}) async {
    if (!isSupported) return;
    _closeToTray = closeToTray;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // 拦截关闭：交给 onWindowClose 决定是隐藏还是真退。
    // 这一步必须先做：万一下面的托盘初始化抛异常，窗口也不能变成"点一下就跑"。
    await windowManager.setPreventClose(true);
    try {
      await _setupTray();
    } on Object catch (error) {
      // 托盘起不来不影响软件本身：窗口照常显示，关闭仍然走拦截逻辑
      // （此时 _closeToTray 为 true，点关闭会隐藏到托盘，用户可以从任务栏图标唤回）。
      LogStore.instance.add('托盘', '初始化失败：$error');
    }
    _applyCaptionColor();
    _initialized = true;
  }

  /// 把系统标题栏染成与界面同色。
  ///
  /// 放在托盘初始化之后：此时窗口已经创建并显示了标题，`FindWindowW` 才能按标题找到它。
  void _applyCaptionColor() {
    // 取界面底色 0xfff6f7f5 附近的一档，跟内容区贴近又不至于分不清边界。
    applyCaptionColorByTitle(_kWindowTitle, 0xf3, 0xf4, 0xf2);
  }

  /// 设置页改了关闭行为：关闭即退出 / 最小化到托盘。
  void applyCloseBehavior(bool closeToTray) {
    if (!_initialized) return;
    _closeToTray = closeToTray;
  }

  Future<void> _setupTray() async {
    final iconPath = await _materializeIcon();
    await trayManager.setIcon(iconPath);
    await trayManager.setContextMenu(
      Menu(
        items: <MenuItem>[
          MenuItem(key: menuShow, label: labels.show),
          MenuItem(key: menuFolder, label: labels.openFolder),
          MenuItem(key: menuPause, label: labels.pauseAll),
          MenuItem.separator(),
          MenuItem(key: menuQuit, label: labels.quit),
        ],
      ),
    );
    trayManager.addListener(this);
  }

  /// 托盘图标要一个真实文件路径：把包内的 .ico 落到数据目录再交给系统。
  Future<String> _materializeIcon() async {
    final data = await rootBundle.load(_iconAsset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final base = Directory.systemTemp;
    final file = File('${base.path}${Platform.pathSeparator}bilicross_tray.ico');
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }

  @override
  Future<void> onWindowClose() async {
    if (_closeToTray) {
      await windowManager.hide();
      return;
    }
    final allowed = await onConfirmQuit();
    if (!allowed) return;
    await _quit();
  }

  /// 真退出：先摘托盘图标，再解除关闭拦截，最后关窗口 —— 顺序反了会留下孤儿图标。
  Future<void> _quit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onTrayIconMouseDown() {
    // 左键单击/双击：把窗口叫回前台。
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Windows 上 tray_manager 不会自动弹菜单：原生只把右键事件转成这个回调，
    // 必须由 Dart 侧主动 popUpContextMenu，否则右键什么都不出。
    // 参数照插件默认值传：把本体窗口置前，避免菜单弹出后点外面不收。
    trayManager.popUpContextMenu();
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case menuShow:
        await windowManager.show();
        await windowManager.focus();
        await onShow();
        break;
      case menuFolder:
        await onOpenFolder();
        break;
      case menuPause:
        await onPauseAll();
        break;
      case menuQuit:
        final allowed = await onConfirmQuit();
        if (allowed) await _quit();
        break;
      default:
        break;
    }
  }
}

/// 托盘与退出确认的文案，界面按当前语言传入。
class DesktopShellLabels {
  const DesktopShellLabels({
    required this.show,
    required this.openFolder,
    required this.pauseAll,
    required this.quit,
  });

  final String show;
  final String openFolder;
  final String pauseAll;
  final String quit;
}
