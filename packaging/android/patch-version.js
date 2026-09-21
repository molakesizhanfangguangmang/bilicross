// 把安卓的 versionName / versionCode 写成指定值。
//
// 用法: node packaging/android/patch-version.js <versionName> <versionCode>
//   例: node packaging/android/patch-version.js 1.1.0.1 19
//
// ⚠️ 为什么要打这个补丁，而不是用 `flutter build --build-name`：
//   实测 —— Flutter 内部按 semver 解析 build-name，**四段会解析失败**
//   （Windows 那侧的版本资源直接退化成 1.0.0，比不传还糟）。
//   而安卓的 versionName 本身接受任意字符串，所以四段号在这里直接写死。
//   android/ 目录不入仓（每次 flutter create 重生），所以补丁在构建期执行。
const fs = require('fs');
const path = require('path');

const NAME = process.argv[2];
const CODE = process.argv[3];

if (!NAME || !CODE) {
  console.error('用法: node packaging/android/patch-version.js <versionName> <versionCode>');
  process.exit(1);
}
if (!/^\d+$/.test(CODE)) {
  console.error('versionCode 必须是整数');
  process.exit(1);
}

const APP_DIR = path.join('android', 'app');
if (!fs.existsSync(APP_DIR)) {
  console.error('未找到 android/app 目录');
  process.exit(1);
}

// 新版模板可能是 build.gradle.kts，两种都认。
const candidates = ['build.gradle', 'build.gradle.kts']
  .map((name) => path.join(APP_DIR, name))
  .filter((file) => fs.existsSync(file));

if (candidates.length === 0) {
  console.error('未找到 android/app/build.gradle(.kts)');
  process.exit(1);
}

let patched = false;
for (const file of candidates) {
  let text = fs.readFileSync(file, 'utf8');
  const before = text;

  // 版本行有好几种写法，全都认：
  //   Groovy 老模板:  versionCode flutterVersionCode.toInteger()
  //   Kotlin DSL:     versionCode = flutterVersionCode.toInteger()
  //   Kotlin DSL 新:  versionCode = flutter.versionCode   ← Flutter 3.47 用的是这个
  //   **已打过补丁的**: versionCode = 24 / versionName = "2.0.2.1"
  // 上一版只认前三种，CI 里就栽在「没有可改的版本行」上。
  //
  // ⚠️ 第四种必须也认（2026-09-21 本地构建实际踩到）：CI 每次都 flutter create
  //   重生 android/，所以永远看到的是模板写法；但**本地编译副本的 android/ 是
  //   复用不重生的**，第二次构建时那两行已经是上一次写进去的字面量，
  //   只认模板写法就会报「没有可改的版本行」而中断，且旧的字面量版本号会
  //   静默留在 gradle 里（比报错更危险的是不报错的那种情况）。
  text = text.replace(
    /versionCode\s*=?\s*(?:flutter\.versionCode|flutterVersionCode\.toInteger\(\)|\d+)/,
    (m) => (m.includes('=') ? `versionCode = ${CODE}` : `versionCode ${CODE}`),
  );
  text = text.replace(
    /versionName\s*=?\s*(?:flutter\.versionName|flutterVersionName|"[^"]*")/,
    (m) =>
      m.includes('=') ? `versionName = "${NAME}"` : `versionName "${NAME}"`,
  );

  if (text === before) {
    console.log(`${file}：没有可改的版本行，跳过`);
    continue;
  }
  fs.writeFileSync(file, text, 'utf8');
  patched = true;
  console.log(`${file}：versionName -> ${NAME}，versionCode -> ${CODE}`);
}

if (!patched) {
  // 幂等：值已经是目标值就算成功（重复跑不该报错），
  // 否则说明模板换了写法，必须报出来 —— 否则版本号会静默编错。
  const already = candidates.some((file) => {
    const text = fs.readFileSync(file, 'utf8');
    return text.includes(CODE) && text.includes(`"${NAME}"`);
  });
  if (already) {
    console.log(`版本已是 ${NAME}（${CODE}），跳过`);
    process.exit(0);
  }
  console.error('没有任何文件被改写 —— 模板里的版本行可能换了写法');
  process.exit(1);
}
