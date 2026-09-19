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
