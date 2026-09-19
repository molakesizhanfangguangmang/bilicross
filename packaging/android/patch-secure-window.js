// 给安卓的 MainActivity 加上 FLAG_SECURE，禁止截屏与录屏（内部测试版需要）。
//
// 用法: node packaging/android/patch-secure-window.js
//
// android/ 目录不入仓（每次 flutter create 重生），所以补丁在构建期执行。
//
// 为什么不用 screen_protector 这类插件：它们是 Kotlin 写的，类在 Kotlin 编译产物里，
// 而 GeneratedPluginRegistrant.java 的编译（compileReleaseJavaWithJavac）先于 Kotlin
// 编译执行，会报 "cannot find symbol: class ScreenProtectorPlugin"。
// 直接改 MainActivity 没有这个问题，也不引入额外依赖。
const fs = require('fs');
const path = require('path');

const ROOT = 'android';

/** 递归找出 MainActivity.kt 的路径。 */
function findMainActivity(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const found = findMainActivity(full);
      if (found) return found;
    } else if (entry.name === 'MainActivity.kt') {
      return full;
    }
  }
  return null;
}

const IMPORT_LINES = [
  'import android.os.Bundle',
  'import android.view.WindowManager',
];

const CLASS_DECL = 'class MainActivity : FlutterActivity()';

const NEW_CLASS = `class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 内部测试版：禁止截屏与录屏，截图会得到黑屏。
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}`;

function patch(file) {
  let text = fs.readFileSync(file, 'utf8');
  if (text.includes('FLAG_SECURE')) {
    console.log('已打过补丁，跳过');
    return;
  }
  if (!text.includes(CLASS_DECL)) {
    console.error('找不到类声明: ' + CLASS_DECL);
    process.exit(1);
  }
  text = text.replace(CLASS_DECL, NEW_CLASS);
  // import 插到最后一条 import 之后。
  const lines = text.split('\n');
  const lastImport = lines.reduce(
    (acc, l, i) => (l.startsWith('import ') ? i : acc),
    -1,
  );
  lines.splice(lastImport + 1, 0, ...IMPORT_LINES);
  text = lines.join('\n');
  fs.writeFileSync(file, text, 'utf8');
  if (!text.includes('FLAG_SECURE')) {
    console.error('注入失败');
    process.exit(1);
  }
  console.log('MainActivity.kt 已启用 FLAG_SECURE');
}

const target = findMainActivity(ROOT);
if (!target) {
  console.error('未找到 MainActivity.kt');
  process.exit(1);
}
patch(target);
console.log('  文件: ' + target);
