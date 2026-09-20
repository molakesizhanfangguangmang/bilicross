// 版本号的**唯一来源**。CI 与本地编译都从这里读，别在别处再写一遍。
//
// 用法:
//   node packaging/version.js            # 打印 name（例如 1.1.0.1）
//   node packaging/version.js --code     # 打印 code（例如 19）
//   node packaging/version.js --flags    # 打印给 flutter build 的两个参数
//
// ⚠️ 为什么四段版本号不在 pubspec.yaml 里：
//   pubspec 的 `version` 必须是标准三段 semver，写 `1.1.0.1+19` 会让
//   `pub get` 直接报 `Invalid version number`。所以 pubspec 只放
//   `1.1.0+19`（三段 + 构建号），四段的 versionName 由构建时注入：
//   `flutter build ... --build-name=1.1.0.1 --build-number=19`。
//   Flutter 对 Android 的 --build-name 不做校验（只有 iOS/macOS 会过滤字符），
//   Android 的 versionName 接受任意字符串；Windows 的 VERSIONINFO 本来就是
//   四段格式，正好对上。
//
// 发版 / 发测试版时改这里：
//   - 测试版：name 第四段 +1，code +1（Android 靠 code 判断新旧，不涨装不上）
//   - 正式版：name 回到三段（1.1.1），code +1
const fs = require('fs');
const path = require('path');

const file = path.join(__dirname, 'version.json');
const info = JSON.parse(fs.readFileSync(file, 'utf8'));

const name = String(info.name || '').trim();
const code = String(info.code || '').trim();

if (!name || !code) {
  console.error('packaging/version.json 里缺少 name 或 code');
  process.exit(1);
}
if (!/^\d+$/.test(code)) {
  console.error('version.json 的 code 必须是整数（Android 的 versionCode 要求）');
  process.exit(1);
}
// name 至少三段；四段是测试版，三段是正式版。
if (!/^\d+(\.\d+){2,3}$/.test(name)) {
  console.error(`version.json 的 name 格式不对：${name}（应为 x.y.z 或 x.y.z.w）`);
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.includes('--code')) {
  console.log(code);
} else if (args.includes('--flags')) {
  console.log(`--build-name=${name} --build-number=${code}`);
} else {
  console.log(name);
}
