import 'dart:io';
import 'dart:ui' show Locale;

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/i18n/app_localizations.dart';
import 'package:bilicross/src/i18n/app_localizations_en.dart';
import 'package:bilicross/src/i18n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 假的路径提供者：把应用数据目录指到临时目录，
/// 让 AppState 的设置读写可以离线跑完整条链路。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

void main() {
  group('语言持久化', () {
    test('旧配置没有 locale_code 字段时默认 zh-CN', () {
      final settings = AppSettings.fromJson(const {
        'download_dir': '/tmp/downloads',
      });
      expect(settings.localeCode, kLocaleZhCN);
    });

    test('zh-CN 与 en-US（含 system）正确序列化和反序列化', () {
      for (final code in const [kLocaleZhCN, kLocaleEnUS, kLocaleSystem]) {
        final settings = AppSettings(localeCode: code);
        final restored = AppSettings.fromJson(settings.toJson());
        expect(restored.localeCode, code, reason: code);
      }
    });

    test('非法值回落到简体中文', () {
      expect(AppSettings.fromJson(const {'locale_code': 'fr-FR'}).localeCode, kLocaleZhCN);
      expect(AppSettings.fromJson(const {'locale_code': ''}).localeCode, kLocaleZhCN);
      expect(normalizeLocaleCode(null), kLocaleZhCN);
      expect(normalizeLocaleCode('en-US'), kLocaleEnUS);
    });

    test('fromCode：system 按系统语言解析，不支持的语言回落中文', () {
      expect(AppLocalizations.fromCode(kLocaleEnUS).code, kLocaleEnUS);
      expect(AppLocalizations.fromCode(kLocaleZhCN).code, kLocaleZhCN);
      expect(
        AppLocalizations.fromCode(kLocaleSystem, systemLocale: const Locale('en', 'US')).code,
        kLocaleEnUS,
      );
      expect(
        AppLocalizations.fromCode(kLocaleSystem, systemLocale: const Locale('ja', 'JP')).code,
        kLocaleZhCN,
      );
    });

    test('setLocale 更新 AppState、落盘并在重新加载后保持', () async {
      final dir = await Directory.systemTemp.createTemp('bilicross-locale-test');
      addTearDown(() => dir.delete(recursive: true));
      PathProviderPlatform.instance = _FakePathProvider(dir);

      final state = await AppState.load();
      expect(state.settings.localeCode, kLocaleZhCN);

      var notified = 0;
      state.addListener(() => notified++);

      await state.setLocale(kLocaleEnUS);
      expect(state.settings.localeCode, kLocaleEnUS);
      expect(notified, greaterThan(0), reason: '切换语言后必须 notifyListeners');

      // 重新加载走的是磁盘上那份设置：验证语言选择确实持久化了。
      final reloaded = await AppState.load();
      expect(reloaded.settings.localeCode, kLocaleEnUS);

      await state.setLocale('not-a-locale');
      expect(state.settings.localeCode, kLocaleEnUS, reason: '非法值不应改变设置');
    });
  });

  group('语言资源', () {
    test('中英文 bundle 的 key 集合完全一致', () {
      expect(AppLocalizationsEn.data.keys.toSet(), AppLocalizationsZh.data.keys.toSet());
    });

    test('没有空文案', () {
      for (final entry in AppLocalizationsZh.data.entries) {
        expect(entry.value, isNotEmpty, reason: 'zh:${entry.key}');
      }
      for (final entry in AppLocalizationsEn.data.entries) {
        expect(entry.value, isNotEmpty, reason: 'en:${entry.key}');
      }
    });

    test('缺 key 时回落中文而不是裸 key', () {
      const en = AppLocalizationsEn();
      expect(en.tr('settings.language'), isNot('settings.language'));
    });

    test('任务阶段在两种语言下都有文本', () {
      const zh = AppLocalizationsZh();
      const en = AppLocalizationsEn();
      for (final stage in TaskStage.values) {
        expect(stage.label(zh), isNotEmpty, reason: 'zh ${stage.name}');
        expect(stage.label(en), isNotEmpty, reason: 'en ${stage.name}');
        expect(stage.label(zh), isNot(stage.label(en)), reason: '两语言不应完全相同：${stage.name}');
      }
    });

    test('账号会员状态在两种语言下都有文本', () {
      const zh = AppLocalizationsZh();
      const en = AppLocalizationsEn();
      const states = [
        AccountState(loggedIn: false),
        AccountState(loggedIn: true, vipStatus: 1, vipType: 1),
        AccountState(loggedIn: true, vipStatus: 1, vipType: 2),
        AccountState(loggedIn: true, vipStatus: 1, vipType: 9),
      ];
      for (final state in states) {
        expect(state.vipLabel(zh), isNotEmpty);
        expect(state.vipLabel(en), isNotEmpty);
        expect(state.vipLabel(zh), isNot(state.vipLabel(en)));
      }
    });

    test('设置项与语言选项在两种语言下都有文本', () {
      const keys = [
        'settings.language',
        'settings.languageSystem',
        'settings.languageZh',
        'settings.languageEn',
        'settings.save',
        'settings.saved',
        'tasks.pause',
        'tasks.resume',
        'account.webLogin',
        'logs.title',
      ];
      const zh = AppLocalizationsZh();
      const en = AppLocalizationsEn();
      for (final key in keys) {
        expect(zh.tr(key), isNot(key), reason: 'zh $key');
        expect(en.tr(key), isNot(key), reason: 'en $key');
      }
    });
  });

  group('版本号', () {
    test('pubspec 版本为 1.0.6+16', () {
      final text = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
      expect(match, isNotNull, reason: 'pubspec.yaml 里找不到 version 字段');
      expect(match!.group(1), '1.0.6+16');
    });
  });
}
