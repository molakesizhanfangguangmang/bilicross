import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_check.dart';

/// 关于弹窗里的纹章图，原图直接打进包里，不做压缩。
const String kCrestAsset = 'assets/branding/crest.png';

/// 打开关于弹窗。用户在里面点了「检测更新」就返回那次结果，
/// 由调用方（页面自己有稳定的 context）去弹确认框或底部的提示。
Future<void> showAppAboutDialog(BuildContext context) async {
  final result = await showDialog<UpdateCheckResult>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => const AppAboutDialog(),
  );
  if (result == null) return;
  if (!context.mounted) return;
  await handleUpdateResult(context, result, notifyWhenUpToDate: true);
}

/// 更新检查结果的统一出口：有新版弹确认框，其余在底部给一句话。
Future<void> handleUpdateResult(
  BuildContext context,
  UpdateCheckResult result, {
  required bool notifyWhenUpToDate,
}) async {
  if (result.outcome == UpdateOutcome.available) {
    await showUpdateConfirmDialog(context, result);
    return;
  }
  if (result.outcome == UpdateOutcome.upToDate && !notifyWhenUpToDate) return;
  if (!context.mounted) return;
  final text =
      result.outcome == UpdateOutcome.upToDate ? '已是最新' : '检测更新失败';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
}

/// 「检测到更新 v1.0.2，是否前往」。
Future<void> showUpdateConfirmDialog(
  BuildContext context,
  UpdateCheckResult result,
) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '关闭',
                iconSize: 18,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                icon: const Icon(Icons.close),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('检测到更新 ${result.latestLabel}，是否前往'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('否'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('是'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (go != true) return;
  if (!context.mounted) return;
  await openExternalUrl(context, result.releaseUrl);
}

/// 用系统浏览器打开地址；打不开就提示一句，不往外抛异常。
Future<void> openExternalUrl(BuildContext context, String url) async {
  var launched = false;
  try {
    launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    launched = false;
  }
  if (launched || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(content: Text('浏览器没有打开'), duration: Duration(seconds: 2)),
    );
}

class AppAboutDialog extends StatefulWidget {
  const AppAboutDialog({super.key});

  @override
  State<AppAboutDialog> createState() => _AppAboutDialogState();
}

class _AppAboutDialogState extends State<AppAboutDialog> {
  /// null 表示还没读出来；空串表示读不到。
  String? _version;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    readCurrentVersion().then((value) {
      if (!mounted) return;
      setState(() => _version = value);
    });
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await checkForUpdate(currentVersion: _version);
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  String get _versionLine {
    final version = _version;
    if (version == null) return '';
    if (version.isEmpty) return '当前版本 未知';
    return '当前版本 $version';
  }

  @override
  Widget build(BuildContext context) {
    // 「检测更新」目前只服务 Android 侧载更新；Windows 包不显示这一格。
    final canCheck = Theme.of(context).platform == TargetPlatform.android;
    final screenWidth = MediaQuery.of(context).size.width;
    final side = screenWidth * 0.9 < 320 ? screenWidth * 0.9 : 320.0;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      backgroundColor: const Color(0xff101212),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: side,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: side,
              height: side,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image.asset(kCrestAsset, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton(
                      tooltip: '关闭',
                      iconSize: 18,
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black45,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 2,
                    child: TextButton(
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      onPressed: () => openExternalUrl(context, kProjectUrl),
                      child: const Text('项目地址', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  if (canCheck)
                    Positioned(
                      right: 6,
                      bottom: 2,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _checking ? null : _check,
                        child: _checking
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('检测更新', style: TextStyle(fontSize: 13)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Text(
                _versionLine,
                style: const TextStyle(fontSize: 12, color: Color(0xff9aa3a0)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
