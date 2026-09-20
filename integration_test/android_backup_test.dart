// 设备上的集成测试：安卓的备份导出路径。
//
// 跑法（要先起模拟器）:
//   flutter test integration_test/android_backup_test.dart -d emulator-5554
//
// ⚠️ 现在导出走**用户口令**派生密钥（format_version 2），不再需要构建期注入的
// 备份密钥 —— 所以本地直接能跑，不用传任何 secret。
// （老格式 v1 仍走注入密钥，那部分由 test/backup_codec_test.dart 覆盖。）
//
// ⚠️ 为什么必须跑在设备上：
//   导出走的是 `Platform.isAndroid` 分支 —— 安卓直接写进下载目录，
//   桌面走「另存为」对话框。宿主机上的 widget test 只会走桌面那条，
//   安卓那条分支**根本覆盖不到**。
//
// ⚠️ 为什么不断言「文件落在某个算出来的路径」：
//   导出成功后界面会弹一条 `已导出备份：<完整路径>`。
//   直接从这条提示里取路径，比在测试里复算一遍数据目录可靠得多
//   （数据目录的解析逻辑以后改了，测试也不会假失败）。

import 'dart:io';

import 'package:bilicross/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 备份文件的 magic：`BCBAKBK1`（见 core/backup/backup_format.dart）。
const List<int> kBackupMagic = <int>[0x42, 0x43, 0x42, 0x41, 0x4B, 0x42, 0x4B, 0x31];

/// 推进若干毫秒。
///
/// ⚠️ **不能用 ** —— 应用里有周期性 timer（下载队列那类），
/// 帧永远不会静止，pumpAndSettle 会一直等到超时（踩过：测试挂死 5 分钟）。
Future<void> _pump(WidgetTester tester, [int ms = 1200]) async {
  var left = ms;
  while (left > 0) {
    await tester.pump(const Duration(milliseconds: 100));
    left -= 100;
  }
}

/// 从当前界面上所有 Text 里找以 [prefix] 开头的那条。
String? _textStartingWith(WidgetTester tester, String prefix) {
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final data = widget.data;
    if (data != null && data.startsWith(prefix)) return data;
  }
  return null;
}

/// 把口令弹框填掉并点确定。
///
/// 导出时是「口令 + 再输一遍」两个输入框，导入时只有一个 ——
/// 这里按实际出现几个来填，两个都填同一个值。
Future<void> _fillPassphrase(WidgetTester tester, String passphrase) async {
  final fields = find.byType(TextField);
  final count = fields.evaluate().length;
  expect(count, greaterThan(0), reason: '应该弹出了口令输入框');
  for (var i = 0; i < count; i++) {
    await tester.enterText(fields.at(i), passphrase);
  }
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('确定').last);
  await tester.pump(const Duration(milliseconds: 300));
}


/// 往下滚到能**看见** [target] 为止。
///
/// ⚠️ 不能用「找到了就返回」来判断：`SingleChildScrollView` 会把所有子控件
/// 一次性建出来，控件在树里但可能停在屏幕外（踩过：按钮 y=1299 超出可视区 914，
/// tap 落在空白处）。`ensureVisible` 才是对的。
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target.first);
  await _pump(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('安卓上备份入口可见，导出会落到下载目录且 magic 正确', (tester) async {
    app.main();
    await _pump(tester, 3000);

    // 底部导航进设置页。
    expect(find.text('设置'), findsWidgets, reason: '底部导航应该有「设置」');
    await tester.tap(find.text('设置').first);
    await _pump(tester);

    // 备份卡片现在两端都有（以前被 if (windows) 挡着）。
    final backupTitle = find.text('备份与恢复');
    await _scrollTo(tester, backupTitle);
    expect(
      backupTitle,
      findsWidgets,
      reason: '安卓上应该能看到「备份与恢复」—— 这正是这次改动要保证的',
    );

    // 点导出。
    final exportButton = find.text('导出备份');
    await _scrollTo(tester, exportButton);
    expect(exportButton, findsWidgets, reason: '应该能找到「导出备份」按钮');
    await tester.tap(exportButton.first);
    await _pump(tester, 1500);

    // 导出现在**必须先设口令**（两遍），把弹框填掉。
    await _fillPassphrase(tester, 'test-passphrase-1234');
    await _pump(tester, 2000);

    // ⚠️ 轮询等待，不用固定时长：加密 + 写盘是 async，固定等容易踩时序。
    // 同时**两条路径都看** —— 原来只找成功提示，失败（弹错误对话框）时
    // 什么都看不到，等于没诊断。
    String? toast;
    String? failure;
    for (var i = 0; i < 75; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      toast = _textStartingWith(tester, '已导出备份：');
      failure = _textStartingWith(tester, '恢复失败：') ??
          _textStartingWith(tester, '导出失败：');
      if (toast != null || failure != null) break;
    }

    // 把应用侧异常也吐出来 —— 不然它会被框架吞掉，只留一行日志。
    final appError = tester.takeException();
    expect(failure, isNull, reason: '导出报了错：$failure');
    expect(appError, isNull, reason: '导出期间应用抛了异常：$appError');
    expect(
      toast,
      isNotNull,
      reason: '导出后应该出现「已导出备份：<路径>」；'
          '既没成功提示也没错误提示，说明点击根本没触发导出',
    );
    final path = toast!.substring('已导出备份：'.length).trim();

    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '导出的备份文件应该真的存在：$path');
    expect(
      path.endsWith('.bcbak'),
      isTrue,
      reason: '备份文件应该是 .bcbak：$path',
    );
    expect(
      path.contains('downloads'),
      isTrue,
      reason: '安卓上应该落在下载目录里：$path',
    );

    final bytes = file.readAsBytesSync();
    expect(
      bytes.length,
      greaterThan(kBackupMagic.length),
      reason: '备份文件不该是空的',
    );
    expect(
      bytes.sublist(0, kBackupMagic.length),
      kBackupMagic,
      reason: '文件头应该是 BCBAKBK1 —— 不匹配说明写出来的不是合法备份',
    );

    // 同一天再导一次不该覆盖前一份。
    await tester.tap(exportButton.first);
    await _pump(tester, 1500);
    await _fillPassphrase(tester, 'test-passphrase-1234');
    await _pump(tester, 2000);
    String? second;
    for (var i = 0; i < 75; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      second = _textStartingWith(tester, '已导出备份：');
      if (second != null) break;
    }
    expect(second, isNotNull, reason: '第二次导出也该有成功提示');
    final secondPath = second!.substring('已导出备份：'.length).trim();
    expect(
      secondPath,
      isNot(path),
      reason: '同一天导出两次应该自动改名，不覆盖：$path vs $secondPath',
    );
    expect(File(secondPath).existsSync(), isTrue);
  });
}
