// 读 PE 头里的 machine 字段，确认产物是不是真的目标架构。
//
// 用法: node packaging/windows/pe-machine.js <文件> [x64|arm64|x86]
//   不带期望架构时只打印结果；带了就比对，不匹配退出码 1。
//
// ⚠️ 为什么需要：在 arm64 宿主上，Flutter 拉不到 arm64 引擎时会**静默回落**成 x64
//   —— 命令行照样报「构建成功」，产物却是 x64。只看退出码会被骗，必须读 PE 头。
const fs = require('fs');

const CODES = { x86: 0x014c, x64: 0x8664, arm64: 0xaa64 };
const NAMES = Object.fromEntries(Object.entries(CODES).map(([k, v]) => [v, k]));

const file = process.argv[2];
const expect = (process.argv[3] || '').toLowerCase();

if (!file) {
  console.error('用法: node packaging/windows/pe-machine.js <文件> [x64|arm64|x86]');
  process.exit(1);
}
if (expect && !(expect in CODES)) {
  console.error(`期望架构只能是 ${Object.keys(CODES).join(' / ')}`);
  process.exit(1);
}

function readMachine(path) {
  const fd = fs.openSync(path, 'r');
  try {
    const head = Buffer.alloc(0x40);
    fs.readSync(fd, head, 0, 0x40, 0);
    if (head.readUInt16LE(0) !== 0x5a4d) throw new Error('缺 MZ 头，不是 PE 文件');
    const peOffset = head.readUInt32LE(0x3c);
    const sig = Buffer.alloc(6);
    fs.readSync(fd, sig, 0, 6, peOffset);
    if (sig.readUInt32LE(0) !== 0x00004550) throw new Error('缺 PE 签名，不是 PE 文件');
    return sig.readUInt16LE(4);
  } finally {
    fs.closeSync(fd);
  }
}

let machine;
try {
  machine = readMachine(file);
} catch (err) {
  console.error(`${file}: 读取失败 —— ${err.message}`);
  process.exit(1);
}

const actual = NAMES[machine] || 'unknown';
const hex = '0x' + machine.toString(16).toUpperCase().padStart(4, '0');
console.log(`${file}: PE machine ${hex} (${actual})`);

if (expect && machine !== CODES[expect]) {
  console.error(`✗ 期望 ${expect}，实际 ${actual}`);
  process.exit(1);
}
