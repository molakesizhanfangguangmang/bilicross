// 把安卓的 applicationId 改成测试版包名，让测试包与正式版可以同时安装。
//
// 用法: node packaging/android/patch-app-id.js <新包名后缀>
//   例: node packaging/android/patch-app-id.js .test
//
// android/ 目录不入仓（每次 flutter create 重生），所以补丁在构建期执行。
//
// 为什么必须改包名：安卓判断"是不是同一个应用"看 applicationId。
// 同包名不同签名会直接装不上（签名不一致），同包名同签名会覆盖安装，
// 只有换成不同包名，系统才视为两个独立应用、允许并存，数据也各自隔离。
const fs = require('fs');
const path = require('path');

const ROOT = 'android';
const SUFFIX = process.argv[2] || '.test';

/** 递归找出 build.gradle.kts 或 build.gradle。 */
function findGradle(dir) {
  const candidates = [];
  (function walk(p) {
    for (const entry of fs.readdirSync(p, { withFileTypes: true })) {
      const full = path.join(p, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (
        entry.name === 'build.gradle.kts' ||
        entry.name === 'build.gradle'
      ) {
        candidates.push(full);
      }
    }
  })(dir);
  // app 模块的那个才是应用级配置。
  return (
    candidates.find((p) => /[\\/]app[\\/]/.test(p)) || candidates[0] || null
  );
}

const file = findGradle(ROOT);
if (!file) {
  console.error('未找到 app 的 build.gradle(.kts)');
  process.exit(1);
}

let text = fs.readFileSync(file, 'utf8');

// 兼容两种写法：
//   Kotlin DSL: applicationId = "io.github.xxx.bilicross"
//   Groovy    : applicationId "io.github.xxx.bilicross"
const patterns = [
  /applicationId\s*=\s*"([^"]+)"/,
  /applicationId\s+"([^"]+)"/,
];

let matched = null;
for (const re of patterns) {
  const m = text.match(re);
  if (m) {
    matched = { re, current: m[1] };
    break;
  }
}

if (!matched) {
  console.error('在 ' + file + ' 里找不到 applicationId');
  process.exit(1);
}

if (matched.current.endsWith(SUFFIX)) {
  console.log('applicationId 已是 ' + matched.current + '，跳过');
  process.exit(0);
}

const next = matched.current + SUFFIX;
text = text.replace(matched.re, (whole) =>
  whole.replace(matched.current, next),
);
fs.writeFileSync(file, text, 'utf8');

if (!text.includes(next)) {
  console.error('改写失败');
  process.exit(1);
}
console.log('applicationId: ' + matched.current + ' -> ' + next);
console.log('  文件: ' + file);
