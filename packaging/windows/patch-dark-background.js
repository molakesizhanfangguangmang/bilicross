// 给 Windows 原生窗口加上深色背景，消除 Flutter 首帧之前的白屏。
//
// 用法: node packaging/windows/patch-dark-background.js [main.cpp 路径]
// 默认路径为 windows/runner/main.cpp（相对当前工作目录，即仓库根）。
//
// 该目录不入仓（每次 flutter create 重生），所以补丁在构建期执行。
//
// 两个必须注意的点：
//   1. main.cpp 是 UTF-8 with BOM。读写往返必须补回 BOM，否则 MSVC 会按本地
//      代码页（中文环境是 936）解析，报 C4819 并被 /WX 提升为错误。
//   2. 注入的注释一律用 ASCII，避免任何编码风险。
const fs = require('fs');

const BOM = '\uFEFF';

/** 注入到 window.SetQuitOnClose 之后的代码块。 */
const INJECT = [
  'window.SetQuitOnClose(true);',
  '',
  '  // Before the first Flutter frame reaches the screen the window shows the',
  '  // system default white background. Attach a dark brush and repaint once so',
  '  // startup does not flash white.',
  '  {',
  '    const COLORREF kBiliCrossSplashColor = RGB(0x14, 0x16, 0x18);',
  '    HBRUSH kBiliCrossSplashBrush = CreateSolidBrush(kBiliCrossSplashColor);',
  '    SetClassLongPtr(window.GetHandle(), GCLP_HBRBACKGROUND,',
  '                    reinterpret_cast<LONG_PTR>(kBiliCrossSplashBrush));',
  '    InvalidateRect(window.GetHandle(), nullptr, TRUE);',
  '    UpdateWindow(window.GetHandle());',
  '  }',
].join('\n');

const ANCHOR = 'window.SetQuitOnClose(true);';

function patchMainCpp(file) {
  if (!fs.existsSync(file)) {
    console.error('找不到文件: ' + file);
    process.exit(1);
  }
  let text = fs.readFileSync(file, 'utf8');
  if (text.includes('kBiliCrossSplashBrush')) {
    console.log('已打过补丁，跳过');
    return;
  }
  if (!text.includes(ANCHOR)) {
    console.error('找不到锚点: ' + ANCHOR);
    process.exit(1);
  }
  text = text.replace(ANCHOR, INJECT);
  // 补回 BOM：原文件有，读写往返不能丢。
  if (!text.startsWith(BOM)) text = BOM + text;
  fs.writeFileSync(file, text, 'utf8');
  const written = fs.readFileSync(file);
  const hasBom =
    written[0] === 0xef && written[1] === 0xbb && written[2] === 0xbf;
  if (!hasBom) {
    console.error('写回后 BOM 丢失');
    process.exit(1);
  }
  if (!text.includes('kBiliCrossSplashBrush')) {
    console.error('注入失败');
    process.exit(1);
  }
  console.log('main.cpp 已注入深色背景（BOM 保留）');
}

patchMainCpp(process.argv[2] || 'windows/runner/main.cpp');
