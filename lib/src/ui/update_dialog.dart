import 'package:flutter/material.dart';

import '../core/update_check.dart';
import '../i18n/app_localizations.dart';
import 'about_dialog.dart' show openExternalUrl;
import 'release_notes_view.dart';

/// 发现新版本时的弹窗：显示版本号、Release 说明，并给出该平台对应的下载按钮。
///
/// [downloadUrl] 为空表示没匹配到对应产物，此时按钮退回 Release 页面。
Future<void> showUpdateAvailableDialog(
  BuildContext context, {
  required UpdateCheckResult result,
  required String? downloadUrl,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dialogContext) =>
        _UpdateAvailableDialog(result: result, downloadUrl: downloadUrl),
  );
}

class _UpdateAvailableDialog extends StatefulWidget {
  const _UpdateAvailableDialog({required this.result, required this.downloadUrl});

  final UpdateCheckResult result;
  final String? downloadUrl;

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  /// 显式持有 controller：RawScrollbar 要靠它接管拖动。
  final ScrollController _notesController = ScrollController();

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = widget.result;
    final direct =
        widget.downloadUrl != null && widget.downloadUrl!.isNotEmpty;
    final target = direct ? widget.downloadUrl! : result.releaseUrl;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: l10n.tr('common.close'),
                iconSize: 18,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l10n.tr('about.updateFound', {
                  'version': result.latestLabel,
                }),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (result.notes.isNotEmpty)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 320),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _ScrollableNotes(
                      controller: _notesController,
                      notes: result.notes,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.tr('common.cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      // 弹窗关掉后再开浏览器，避免在 dialogContext 上起副作用。
                      openExternalUrl(context, target);
                    },
                    child: Text(
                      direct
                          ? l10n.tr('about.download')
                          : l10n.tr('about.openRelease'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 说明区域：可滚轮滚动，也可用鼠标拖动滑块。
///
/// 用 [RawScrollbar] 并把 thumb / track 都设为常显：
/// 滚动条淡出后（内部 fadeout 动画归零）命中检测会直接返回 false，
/// 鼠标按住滑块拖不动，只剩滚轮可用。常显可以避开这条路径。
///
/// 滑块颜色走主题：默认色偏淡，这里指定一个更实的灰，
/// 在小弹窗里看得更清楚。
class _ScrollableNotes extends StatelessWidget {
  const _ScrollableNotes({required this.controller, required this.notes});

  final ScrollController controller;
  final String notes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStatePropertyAll<Color>(
          scheme.onSurfaceVariant.withValues(alpha: 0.72),
        ),
        trackColor: WidgetStatePropertyAll<Color>(
          scheme.onSurfaceVariant.withValues(alpha: 0.10),
        ),
      ),
      child: RawScrollbar(
        controller: controller,
        thumbVisibility: true,
        trackVisibility: true,
        interactive: true,
        child: SingleChildScrollView(
          controller: controller,
          // 右侧留出滚动条宽度，正文不会被压在滑块下面。
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
          child: ReleaseNotesView(notes: notes),
        ),
      ),
    );
  }
}
