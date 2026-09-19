// 把安卓的应用显示名改成测试版名称，便于与正式版区分。
//
// 用法: node packaging/android/patch-app-label.js [名称]
//   例: node packaging/android/patch-app-label.js "逸轨·内部测试版"
//
// android/ 目录不入仓（每次 flutter create 重生），所以补丁在构建期执行。
const fs = require('fs');
const path = require('path');

const ROOT = 'android';
const LABEL = process.argv[2] || '逸轨·内部测试版';

/** 递归找出 AndroidManifest.xml，取 main 那份。 */
function findManifest(dir) {
  const all = [];
  (function walk(p) {
    for (const entry of fs.readdirSync(p, { withFileTypes: true })) {
      const full = path.join(p, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.name === 'AndroidManifest.xml') {
        all.push(full);
      }
    }
  })(dir);
  return all.find((p) => /[\\/]main[\\/]/.test(p)) || all[0] || null;
}

const file = findManifest(ROOT);
if (!file) {
  console.error('未找到 AndroidManifest.xml');
  process.exit(1);
}

let text = fs.readFileSync(file, 'utf8');

// application 标签上的 android:label="..."
const re = /(android:label=")([^"]*)(")/;
const m = text.match(re);
if (!m) {
  console.error('在 ' + file + ' 里找不到 android:label');
  process.exit(1);
}

if (m[2] === LABEL) {
  console.log('android:label 已是 ' + LABEL + '，跳过');
  process.exit(0);
}

const previous = m[2];
text = text.replace(re, (whole, a, _old, c) => a + LABEL + c);
fs.writeFileSync(file, text, 'utf8');

if (!text.includes('android:label="' + LABEL + '"')) {
  console.error('改写失败');
  process.exit(1);
}
console.log('android:label: ' + previous + ' -> ' + LABEL);
console.log('  文件: ' + file);
