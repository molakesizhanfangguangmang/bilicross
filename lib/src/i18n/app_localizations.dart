import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

/// 语言设置的代码。存进 AppSettings，也用于下拉框取值。
const String kLocaleSystem = 'system';
const String kLocaleZhCN = 'zh-CN';
const String kLocaleEnUS = 'en-US';

/// 语言选项的展示顺序：跟随系统、简体中文、English。
const List<String> kLocaleCodes = [kLocaleSystem, kLocaleZhCN, kLocaleEnUS];

/// 界面文案。一份字符串表同时给两处用：
/// - Widget 层走 [AppLocalizations.of]，靠 Localizations 跟着 locale 自动重建；
/// - [AppState] 这类没有 context 的地方走 [AppLocalizations.fromCode]，
///   用设置里的语言代码直接取，任务消息、异常提示因此也是可翻译的。
abstract class AppLocalizations {
  const AppLocalizations();

  static const List<Locale> supportedLocales = [
    Locale('zh', 'CN'),
    Locale('en', 'US'),
  ];

  /// 语言代码，与 AppSettings.localeCode 的取值一致（不含 system）。
  String get code;

  Map<String, String> get values;

  Locale get locale =>
      code == kLocaleEnUS ? const Locale('en', 'US') : const Locale('zh', 'CN');

  /// 取一条文案。`args` 用来填 `{name}` 占位，避免拼接出不好翻译的句子。
  String tr(String key, [Map<String, Object?>? args]) {
    // 英文缺条目时回落中文：漏翻不该让界面变成 key。
    var text = values[key] ?? const AppLocalizationsZh().values[key] ?? key;
    if (args != null) {
      for (final entry in args.entries) {
        text = text.replaceAll('{${entry.key}}', '${entry.value}');
      }
    }
    return text;
  }

  /// Widget 层入口。没取到（比如测试里没挂 delegate）时给中文，不返回 null。
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        const AppLocalizationsZh();
  }

  /// 按设置里的语言代码解析。`system` 表示跟随系统，
  /// 系统语言不在支持列表里时回落简体中文（新装与旧配置都默认中文）。
  static AppLocalizations fromCode(String code, {Locale? systemLocale}) {
    final resolved = resolveCode(code, systemLocale: systemLocale);
    return resolved == kLocaleEnUS
        ? const AppLocalizationsEn()
        : const AppLocalizationsZh();
  }

  /// 只解析代码，不构造文案对象。给需要判断语言的调用方用。
  static String resolveCode(String code, {Locale? systemLocale}) {
    if (code == kLocaleEnUS || code == kLocaleZhCN) return code;
    final locale = systemLocale ?? PlatformDispatcher.instance.locale;
    final language = locale.languageCode.toLowerCase();
    if (language == 'en') return kLocaleEnUS;
    return kLocaleZhCN;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    final language = locale.languageCode.toLowerCase();
    return language == 'zh' || language == 'en';
  }

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(
        locale.languageCode.toLowerCase() == 'en'
            ? const AppLocalizationsEn()
            : const AppLocalizationsZh(),
      );

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
