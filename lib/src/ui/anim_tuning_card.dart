import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/anim_config.dart';
import '../i18n/app_localizations.dart';
import './palette.dart';

/// 展开动画的可调项。
///
/// 只有长按设置页的「高级设置」入口解锁后才会出现在这里
/// （见 `AppSettings.animTuningUnlocked`）；解锁后不提供关回去的入口。
///
/// 这里的参数只作用于安卓：桌面端屏幕大、观感不同，维持原有曲线与展开方式。
class AnimTuningCard extends StatefulWidget {
  const AnimTuningCard({super.key, required this.state});

  final AppState state;

  @override
  State<AnimTuningCard> createState() => _AnimTuningCardState();
}

class _AnimTuningCardState extends State<AnimTuningCard> {
  /// 改完即落盘：这些是调试项，没有「保存」按钮，改了就该记住。
  Future<void> _update(VoidCallback change) async {
    setState(change);
    await widget.state.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = widget.state.settings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.animation),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(l10n.tr('settings.animTitle')),
                      const SizedBox(height: 2),
                      Text(
                        l10n.tr('settings.animHint'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: kTextMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Text(
                  l10n.tr('settings.animDuration'),
                  style: const TextStyle(fontSize: 13),
                ),
                Expanded(
                  child: Slider(
                    value: settings.animDurationMs.toDouble(),
                    min: kAnimMinDurationMs.toDouble(),
                    max: kAnimMaxDurationMs.toDouble(),
                    divisions: (kAnimMaxDurationMs - kAnimMinDurationMs) ~/ 20,
                    label: '${settings.animDurationMs} ms',
                    onChanged: (value) => _update(
                      () => settings.animDurationMs = clampAnimDuration(
                        value.round(),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 62,
                  child: Text(
                    '${settings.animDurationMs} ms',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.tr('settings.animCurve'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final name in kAnimCurves.keys)
                  ChoiceChip(
                    label: Text(l10n.tr('settings.animCurve.$name')),
                    selected: settings.animCurve == name,
                    onSelected: (_) => _update(() => settings.animCurve = name),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.tr('settings.animStyle'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final name in kAnimStyles)
                  ChoiceChip(
                    label: Text(l10n.tr('settings.animStyle.$name')),
                    selected: settings.animStyle == name,
                    onSelected: (_) => _update(() => settings.animStyle = name),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
