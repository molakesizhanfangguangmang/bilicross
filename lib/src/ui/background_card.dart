import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/background_config.dart';
import '../i18n/app_localizations.dart';
import 'palette.dart';

/// 设置页「界面与语言」组里的背景控件：选图 / 清除 + 铺满方式 +
/// 卡片与上下栏两个不透明度滑杆。
///
/// 不用 [SectionCard]：本控件是嵌在「界面与语言」那个分组卡片里的，
/// 再套一层卡片就成了卡中卡。
///
/// 图会复制进数据目录，之后挪走或删掉原文件都不影响。
class BackgroundCard extends StatefulWidget {
  const BackgroundCard({super.key, required this.state});

  final AppState state;

  @override
  State<BackgroundCard> createState() => _BackgroundCardState();
}

class _BackgroundCardState extends State<BackgroundCard> {
  bool _busy = false;

  AppState get _state => widget.state;

  /// 当前是否已有一张可用的背景图。
  bool get _hasImage => backgroundImageFile(_state.store.root).existsSync();

  Future<void> _pick() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      // 用 file_picker 的静态 API（13.x 起没有 FilePicker.platform）：
      // pickFiles 直接返回 List<PlatformFile>（用户取消就是空表），
      // 没有 FilePickerResult 包装；PlatformFile.path 仍是可空。
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['png', 'jpg', 'jpeg', 'webp', 'bmp'],
      );
      if (picked.isEmpty) return;
      final path = picked.first.path;
      if (path == null || path.isEmpty) return;
      final ok = await saveBackgroundImage(_state.store.root, path);
      if (!mounted) return;
      if (!ok) {
        _toast(l10n.tr('background.imageFailed'));
        return;
      }
      // 浓度是 0 时选完图什么也看不见，顺手拉回默认值。
      if (clampBackgroundOpacity(_state.settings.backgroundOpacity) <=
          kBackgroundMinOpacity) {
        _state.settings.backgroundOpacity = kBackgroundDefaultOpacity;
      }
      await _state.saveSettings();
      if (!mounted) return;
      setState(() {});
      _toast(l10n.tr('background.imageSaved'));
    } on Object catch (error) {
      if (!mounted) return;
      _toast(l10n.tr('background.imageFailedWith', {'error': '$error'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    await removeBackgroundImage(_state.store.root);
    if (!mounted) return;
    setState(() {});
    // 图是文件不是设置字段：删完得主动敲一下，外壳才知道要撤掉背景层。
    _state.notifyAppearanceChanged();
    _toast(AppLocalizations.of(context).tr('background.imageCleared'));
  }

  /// 拖动中只发通知做实时预览，松手才落盘。
  ///
  /// ⚠️ 不能每动一格就 [AppState.saveSettings]：那是写盘 + 重建 API + 探测 ffmpeg。
  void _preview() => _state.notifyAppearanceChanged();

  void _persist() => unawaited(_state.saveSettings());

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = _state.settings;
    final background = clampBackgroundOpacity(settings.backgroundOpacity);
    final ui = clampUiOpacity(settings.uiOpacity);
    final bar = clampBarOpacity(settings.barOpacity);
    final fit = normalizeBackgroundFit(settings.backgroundFit);
    const hint = TextStyle(fontSize: 12, color: kTextMuted);
    const label = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.tr('background.title'), style: label),
        const SizedBox(height: 4),
        Text(l10n.tr('background.hint'), style: hint),
        const SizedBox(height: 10),
        Text(
          _hasImage
              ? l10n.tr('background.imageSet')
              : l10n.tr('background.imageNone'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.image_outlined),
              label: Text(l10n.tr('background.pickImage')),
            ),
            const SizedBox(width: 8),
            if (_hasImage)
              TextButton.icon(
                onPressed: _busy ? null : _clear,
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.tr('background.clearImage')),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          l10n.tr('background.opacity', {
            'value': '${(background * 100).round()}',
          }),
        ),
        Slider(
          value: background,
          min: kBackgroundMinOpacity,
          max: kBackgroundMaxOpacity,
          divisions: 20,
          label: '${(background * 100).round()}%',
          onChanged: (value) {
            settings.backgroundOpacity = clampBackgroundOpacity(value);
            setState(() {});
            _preview();
          },
          onChangeEnd: (_) => _persist(),
        ),
        Text(l10n.tr('background.opacityHint'), style: hint),
        const SizedBox(height: 14),
        Text(l10n.tr('background.fit'), style: label),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final value in kBackgroundFits)
              ChoiceChip(
                label: Text(l10n.tr('background.fit.$value')),
                selected: fit == value,
                onSelected: (selected) {
                  if (!selected) return;
                  setState(() => settings.backgroundFit = value);
                  _persist();
                },
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          l10n.tr('background.cardOpacity', {'value': '${(ui * 100).round()}'}),
        ),
        Slider(
          value: ui,
          min: kUiMinOpacity,
          max: kUiMaxOpacity,
          divisions: 16,
          label: '${(ui * 100).round()}%',
          onChanged: (value) {
            settings.uiOpacity = clampUiOpacity(value);
            setState(() {});
            _preview();
          },
          onChangeEnd: (_) => _persist(),
        ),
        Text(l10n.tr('background.cardOpacityHint'), style: hint),
        const SizedBox(height: 20),
        Text(
          l10n.tr('background.barOpacity', {'value': '${(bar * 100).round()}'}),
        ),
        Slider(
          value: bar,
          min: kBarMinOpacity,
          max: kBarMaxOpacity,
          divisions: 18,
          label: '${(bar * 100).round()}%',
          onChanged: (value) {
            settings.barOpacity = clampBarOpacity(value);
            setState(() {});
            _preview();
          },
          onChangeEnd: (_) => _persist(),
        ),
        Text(l10n.tr('background.barOpacityHint'), style: hint),
      ],
    );
  }
}
