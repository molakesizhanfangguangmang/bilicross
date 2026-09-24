import 'dart:io';

/// 背景图在数据目录里的文件名。
///
/// 固定一个名字：换图直接覆盖，不用追踪历史文件、也无需清理。
/// 后缀统一用 `.img`：Flutter 解码靠内容而非扩展名，避开格式判断。
const String kBackgroundImageName = 'background.img';

/// 背景不透明度的上下限。下限 0 表示「关掉背景」—— 不额外存开关。
const double kBackgroundMinOpacity = 0.0;
const double kBackgroundMaxOpacity = 1.0;

/// 默认浓度：选了图就按这个值显示，不至于选完什么也看不见。
const double kBackgroundDefaultOpacity = 0.6;

/// 卡片不透明度（浮在背景上的那层面板）的上下限。
///
/// ⚠️ 下限刻意不是 0：调到 0 卡片就彻底看不见了，连设置页的滑杆都点不回来。
/// 20% 是防呆线，不是「好看的下限」。
const double kUiMinOpacity = 0.2;
const double kUiMaxOpacity = 1.0;
const double kUiDefaultOpacity = 1.0;

/// 上下栏（顶栏 + 底部导航 / 宽屏侧栏）不透明度的上下限。
///
/// 下限比卡片更低：这两条是窄边、压住的文字少，拖到 10% 还认得出来。
const double kBarMinOpacity = 0.1;
const double kBarMaxOpacity = 1.0;
const double kBarDefaultOpacity = 1.0;

/// 背景图解码上限（物理像素，长边）。
///
/// ⚠️ 不按窗口尺寸算：那样拖一次窗口就换一次解码目标，得再引一层 resize 防抖。
/// 固定上限既压住内存（4K 原图直解要 30+ MB，安卓容易 OOM），也不用防抖。
const int kBackgroundDecodeCap = 2048;

/// 铺满方式：撑满裁切 / 完整显示 / 平铺。
const String kBackgroundFitCover = 'cover';
const String kBackgroundFitContain = 'contain';
const String kBackgroundFitTile = 'tile';
const String kBackgroundFitDefault = kBackgroundFitCover;
const List<String> kBackgroundFits = <String>[
  kBackgroundFitCover,
  kBackgroundFitContain,
  kBackgroundFitTile,
];

/// 存盘里可能是旧值或手工改过的值，认不出来就回落到默认。
String normalizeBackgroundFit(String? raw) =>
    raw != null && kBackgroundFits.contains(raw) ? raw : kBackgroundFitDefault;

/// 把浓度收进合法区间。配置被手改坏时也不至于出格。
double clampBackgroundOpacity(double value) {
  if (value.isNaN) return kBackgroundDefaultOpacity;
  if (value < kBackgroundMinOpacity) return kBackgroundMinOpacity;
  if (value > kBackgroundMaxOpacity) return kBackgroundMaxOpacity;
  return value;
}

/// 同上，卡片不透明度。
double clampUiOpacity(double value) {
  if (value.isNaN) return kUiDefaultOpacity;
  if (value < kUiMinOpacity) return kUiMinOpacity;
  if (value > kUiMaxOpacity) return kUiMaxOpacity;
  return value;
}

/// 同上，上下栏不透明度。
double clampBarOpacity(double value) {
  if (value.isNaN) return kBarDefaultOpacity;
  if (value < kBarMinOpacity) return kBarMinOpacity;
  if (value > kBarMaxOpacity) return kBarMaxOpacity;
  return value;
}

/// 背景图在磁盘上的位置。数据根目录由调用方给出（安装版 / 便携版不同）。
File backgroundImageFile(Directory dataRoot) =>
    File('${dataRoot.path}${Platform.pathSeparator}$kBackgroundImageName');

/// 把用户选的图复制进数据目录，返回是否成功。
///
/// 复制而不是记路径：用户之后挪走或删掉原文件也不影响背景。
Future<bool> saveBackgroundImage(Directory dataRoot, String sourcePath) async {
  try {
    final source = File(sourcePath);
    if (!await source.exists()) return false;
    if (!dataRoot.existsSync()) {
      await dataRoot.create(recursive: true);
    }
    final target = backgroundImageFile(dataRoot);
    // 同路径直接赋值会报错，先删掉再拷。
    if (target.existsSync()) await target.delete();
    await source.copy(target.path);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 删掉已保存的背景图；没有也当成功。
Future<void> removeBackgroundImage(Directory dataRoot) async {
  try {
    final target = backgroundImageFile(dataRoot);
    if (target.existsSync()) await target.delete();
  } on FileSystemException {
    // 删不掉就留着，不影响后续使用（读不到会回落到无背景）。
  }
}
