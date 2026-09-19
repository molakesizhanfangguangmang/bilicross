import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/splash_config.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';

/// 设置页的「启动画面」卡片：开屏开关、选图、停留时长。
///
/// 图会复制进数据目录，之后挪走或删掉原文件都不影响启动。
class SplashCard extends StatefulWidget {
  const SplashCard({super.key, required this.state});

  final AppState state;

  @override
  State<SplashCard> createState() => _SplashCardState();
}

class _SplashCardState extends State<SplashCard> {
  bool _busy = false;

  AppState get _state => widget.state;

  /// 当前是否已有一张可用的开屏图。
  bool get _hasImage => splashImageFile(_state.store.root).existsSync();

  Future<void> _pick() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      // 用 file_picker 的静态 API（13.x 起没有 FilePicker.platform）：
      // pickFiles 直接返回 List<PlatformFile>（非空列表，用户取消就是空表），
      // 没有 FilePickerResult 包装；PlatformFile.path 仍是可空。
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['png', 'jpg', 'jpeg', 'webp', 'bmp'],
      );
      if (picked.isEmpty) return;
      final path = picked.first.path;
      if (path == null || path.isEmpty) return;
      final ok = await saveSplashImage(_state.store.root, path);
      if (!mounted) return;
      if (!ok) {
        _toast(l10n.tr('splash.imageFailed'));
        return;
      }
      // 选了图就顺带把开关打开：不然用户以为选完就生效了。
      _state.settings.splashEnabled = true;
      await _state.saveSettings();
      if (!mounted) return;
      setState(() {});
      _toast(l10n.tr('splash.imageSaved'));
    } on Object catch (error) {
      if (!mounted) return;
      _toast(l10n.tr('splash.imageFailedWith', {'error': '$error'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    await removeSplashImage(_state.store.root);
    if (!mounted) return;
    setState(() {});
    _toast(AppLocalizations.of(context).tr('splash.imageCleared'));
  }

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
    final seconds = clampSplashSeconds(settings.splashSeconds);

    return SectionCard(
      title: l10n.tr('splash.title'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.splashEnabled,
            title: Text(l10n.tr('splash.enable')),
            subtitle: Text(l10n.tr('splash.enableHint')),
            onChanged: _busy
                ? null
                : (value) {
                    settings.splashEnabled = value;
                    setState(() {});
                  },
          ),
          const SizedBox(height: 4),
          Text(
            _hasImage ? l10n.tr('splash.imageSet') : l10n.tr('splash.imageNone'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.image_outlined),
                label: Text(l10n.tr('splash.pickImage')),
              ),
              const SizedBox(width: 8),
              if (_hasImage)
                TextButton.icon(
                  onPressed: _busy ? null : _clear,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.tr('splash.clearImage')),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(l10n.tr('splash.seconds', {'value': seconds.toStringAsFixed(1)})),
          Slider(
            value: seconds,
            min: kSplashMinSeconds,
            max: kSplashMaxSeconds,
            divisions: 10,
            label: '${seconds.toStringAsFixed(1)}s',
            onChanged: (value) {
              settings.splashSeconds = clampSplashSeconds(value);
              setState(() {});
            },
          ),
          Text(
            l10n.tr('splash.hint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
