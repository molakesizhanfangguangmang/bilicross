import 'dart:io';

/// 发行通道。
///
/// 同一份代码要区分安装版与便携版：数据放哪、能不能自动更新都不一样。
/// 判定依据是**构建期注入的常量**（CI 构建便携版时传
/// `--dart-define=BILICROSS_CHANNEL=portable`），而不是「看当前目录里有没有某个文件」——
/// 后者在用户把便携版放到别处运行、或被安装程序解包时就认错了。
enum ReleaseChannel {
  /// 安装版：程序在安装目录，用户数据放 `%LOCALAPPDATA%\BiliCross`。
  installed,

  /// 便携版：解压即用，用户数据放程序旁的 `data` 目录。
  portable,
}

/// 构建期注入的通道标记。
const String kChannelDefine = String.fromEnvironment('BILICROSS_CHANNEL');

/// 便携版标记文件名。编译期常量是主判据，这个文件是兜底：
/// 便携包被误装进程序目录、或安装包被当便携包解压时，仍能认出来。
const String kPortableMarker = 'portable.marker';

/// 把构建期常量翻译成通道。空值或未知值都按安装版处理。
ReleaseChannel channelFromDefine([String value = kChannelDefine]) =>
    value.trim().toLowerCase() == 'portable'
        ? ReleaseChannel.portable
        : ReleaseChannel.installed;

/// 解析用户数据根目录（设置、任务、日志、凭据、回滚备份都在它下面）。
///
/// - Windows 安装版：`%LOCALAPPDATA%\BiliCross`
/// - Windows 便携版：`<程序所在目录>\data`
/// - 其它平台（Android 等）：`<系统应用支持目录>/bilicross`，与旧版本一致，不动
///
/// 参数都可注入，便于测试；不传时取真实平台信息。
Directory resolveDataRoot({
  ReleaseChannel? channel,
  bool? isWindows,
  String? executablePath,
  Map<String, String>? environment,
  required Directory systemSupportDirectory,
}) {
  final sep = Platform.pathSeparator;
  final win = isWindows ?? Platform.isWindows;
  if (!win) {
    return Directory('${systemSupportDirectory.path}${sep}bilicross');
  }
  if ((channel ?? channelFromDefine()) == ReleaseChannel.portable) {
    final exe = executablePath ?? Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    return Directory('$dir${sep}data');
  }
  final env = environment ?? Platform.environment;
  final local = (env['LOCALAPPDATA'] ?? '').trim();
  final base = local.isEmpty ? systemSupportDirectory.path : local;
  return Directory('$base${sep}BiliCross');
}

/// 旧版本可能留下的数据目录（1.0.5 及以前，Windows 上放在应用支持目录下）。
///
/// 顺序即优先级：先 bilicross，再更早的 biliharbor。
List<Directory> legacyDataRoots(Directory systemSupportDirectory) {
  final sep = Platform.pathSeparator;
  return <Directory>[
    Directory('${systemSupportDirectory.path}${sep}bilicross'),
    Directory('${systemSupportDirectory.path}${sep}biliharbor'),
  ];
}

/// 便携版标记文件路径：放在数据目录旁边（程序目录），不在数据目录里面 ——
/// 数据目录可能被用户清掉，标记不该跟着消失。
File portableMarkerFile(String executablePath) =>
    File('${File(executablePath).parent.path}${Platform.pathSeparator}$kPortableMarker');

/// 目标目录不存在、而候选旧目录存在时，把旧数据整体搬过来。
///
/// 为什么必须搬：1.0.5 及以前 Windows 只有一种数据位置（应用支持目录），
/// 1.0.6 起按通道分开放，不搬的话老用户升级后会以为账号和设置被清空。
/// 跨盘 rename 会失败，此时退化成逐文件复制。
Future<Directory> migrateIfNeeded({
  required Directory target,
  required List<Directory> legacyCandidates,
}) async {
  if (target.existsSync()) return target;
  for (final legacy in legacyCandidates) {
    if (legacy.path == target.path) continue;
    if (!legacy.existsSync()) continue;
    target.parent.createSync(recursive: true);
    try {
      legacy.renameSync(target.path);
      return target;
    } on FileSystemException {
      await _copyTree(legacy, target);
      return target;
    }
  }
  target.createSync(recursive: true);
  return target;
}

Future<void> _copyTree(Directory from, Directory to) async {
  to.createSync(recursive: true);
  final sep = Platform.pathSeparator;
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(from.path.length);
    final destination = '${to.path}$relative';
    if (entity is Directory) {
      Directory(destination).createSync(recursive: true);
    } else if (entity is File) {
      final parent = File(destination).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      entity.copySync(destination);
    }
  }
}
