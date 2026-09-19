import 'dart:io';

/// 开屏停留时长的上下限（秒）。
const double kSplashMinSeconds = 0;
const double kSplashMaxSeconds = 5;

/// 用户自选的开屏图在数据目录里的文件名。
///
/// 固定一个名字：换图直接覆盖，不用追踪历史文件、也无需清理。
/// 后缀统一用 `.img`：Flutter 解码靠内容而非扩展名，避开格式判断。
const String kSplashImageName = 'splash.img';

/// 把配置里的秒数收进合法区间。配置被手改坏时也不至于出格。
double clampSplashSeconds(double value) {
  if (value.isNaN) return 2.0;
  if (value < kSplashMinSeconds) return kSplashMinSeconds;
  if (value > kSplashMaxSeconds) return kSplashMaxSeconds;
  return value;
}

/// 开屏图在磁盘上的位置。数据根目录由调用方给出（安装版 / 便携版不同）。
File splashImageFile(Directory dataRoot) =>
    File('${dataRoot.path}${Platform.pathSeparator}$kSplashImageName');

/// 把用户选的图复制进数据目录，返回是否成功。
///
/// 复制而不是记路径：用户之后挪走或删掉原文件也不影响开屏。
Future<bool> saveSplashImage(Directory dataRoot, String sourcePath) async {
  try {
    final source = File(sourcePath);
    if (!await source.exists()) return false;
    if (!dataRoot.existsSync()) {
      await dataRoot.create(recursive: true);
    }
    final target = splashImageFile(dataRoot);
    // 同路径直接赋值会报错，先删掉再拷。
    if (target.existsSync()) await target.delete();
    await source.copy(target.path);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 删掉已保存的开屏图；没有也当成功。
Future<void> removeSplashImage(Directory dataRoot) async {
  try {
    final target = splashImageFile(dataRoot);
    if (target.existsSync()) await target.delete();
  } on FileSystemException {
    // 删不掉就留着，不影响后续启动（读不到会回落到默认）。
  }
}
