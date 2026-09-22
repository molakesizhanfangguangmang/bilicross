// 版本号的**唯一来源**。CI 与本地编译都从这里读，别在别处再写一遍。
//
// 用法:
//   node packaging/version.js            # 完整版本号：正式版 1.1.0
//   node packaging/version.js --base     # 三段基础版本：1.1.0（给平台用）
//   node packaging/version.js --test     # 第四段（正式版为空）
//   node packaging/version.js --code     # versionCode：19
//
// ⚠️ 为什么四段版本号不能走 `flutter build --build-name`：
//   实测过 —— Flutter 内部按 semver 解析 build-name，**四段解析失败**，
//   Windows 的版本资源直接退化成 `1.0.0`，比不传还糟。
//   所以平台版本（APK 的 versionName、exe 的 VERSIONINFO）永远用三段 `base`，
//   第四段只在本地内测构建时另行注入。
//
// 改版本时改这里：
//   - 正式版：base 换新版本号，test 归 0，code +1
//   - 本地内测：test +1，code +1（Android 靠 code 判断新旧，不涨装不上）
const fs = require('fs');
const path = require('path');

const file = path.join(__dirname, 'version.json');
const info = JSON.parse(fs.readFileSync(file, 'utf8'));

const base = String(info.base || '').trim();
const test = Number(info.test || 0);
const code = String(info.code || '').trim();

if (!/^\d+(\.\d+){2}$/.test(base)) {
  console.error(`version.json 的 base 格式不对：${base}（应为 x.y.z）`);
  process.exit(1);
}
if (!Number.isInteger(test) || test < 0) {
  console.error(`version.json 的 test 必须是非负整数：${info.test}`);
  process.exit(1);
}
if (!/^\d+$/.test(code)) {
  console.error('version.json 的 code 必须是整数（Android 的 versionCode 要求）');
  process.exit(1);
}

const full = test > 0 ? `${base}.${test}` : base;
const args = process.argv.slice(2);

if (args.includes('--base')) {
  console.log(base);
} else if (args.includes('--test')) {
  console.log(test > 0 ? String(test) : '');
} else if (args.includes('--code')) {
  console.log(code);
} else {
  console.log(full);
}
