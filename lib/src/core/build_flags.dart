/// 构建期开关，由 CI 通过 `--dart-define` 传入。
///
/// 本地直接 `flutter run` 或 `flutter build` 不传时取 false，也就是**正式形态** ——
/// 这样本地调试看到的就是用户最终看到的样子，不会被测试标记干扰。
library;

/// 是否为内部测试构建。
///
/// 为 true 时才会出现：
/// - 页面水印；
/// - 首页标题与关于页版本的「内部测试版」标识；
/// - 关于页的用途警示语。
///
/// 安卓侧还有构建期的额外处理（换 `.test` 包名、改应用显示名、启用禁截图），
/// 那些在 CI 里由同一个开关控制，不走这个常量。
const bool kTestBuild = bool.fromEnvironment('BILICROSS_TEST_BUILD');

/// 测试版的第四段版本号（例如 `1.1.0` + `1` → `1.1.0.1`）。
///
/// ⚠️ 为什么不用 `flutter build --build-name=1.1.0.1`：
///   Flutter 内部按 semver 解析 build-name，**四段会解析失败**，
///   Windows 那侧的版本资源直接退化成 `1.0.0`（实测过），比不传还糟。
///   所以平台版本仍走三段（pubspec 里的 `1.1.0+19`），
///   第四段在这里拼上去，只影响**应用里显示的版本号**。
///
/// 空串表示不带第四段（正式版）。
const String kTestVersionSuffix = String.fromEnvironment('BILICROSS_TEST_VERSION');
