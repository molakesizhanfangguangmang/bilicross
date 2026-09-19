import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/distribution.dart';
import '../core/release_target.dart';
import '../core/update_check.dart';
import '../i18n/app_localizations.dart';
import 'update_dialog.dart';

/// 关于弹窗顶部的图：应用图标的原图（1440×2038，直接打进包里）。
const String kAppIconAsset = 'assets/branding/app_icon.png';

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

/// 更新检查结果的统一出口：有新版弹说明弹窗，其余在底部给一句话。
///
/// [androidAbi] 由调用方传 `Abi.current()` 的结果：Android 上拿不到
/// `Platform.environment`，只能这样把 ABI 传进来。
Future<void> handleUpdateResult(
  BuildContext context,
  UpdateCheckResult result, {
  required bool notifyWhenUpToDate,
  String? androidAbi,
}) async {
  if (result.outcome == UpdateOutcome.available) {
    await showUpdateAvailableDialog(
      context,
      result: result,
      downloadUrl: _pickDownloadUrl(result.assets, androidAbi: androidAbi),
    );
    return;
  }
  if (result.outcome == UpdateOutcome.upToDate && !notifyWhenUpToDate) return;
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final text = result.outcome == UpdateOutcome.upToDate
      ? l10n.tr('about.upToDate')
      : l10n.tr('about.checkFailed');
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
}

/// 按当前平台、架构与发行通道挑出该下载哪一个产物；挑不到返回 null。
///
/// 挑不到时弹窗会退回 Release 页面，不让用户卡在一个点不动的按钮上。
String? _pickDownloadUrl(List<ReleaseAsset> assets, {String? androidAbi}) {
  final asset = pickAssetFor(
    assets: assets,
    isWindows: Platform.isWindows,
    isAndroid: Platform.isAndroid,
    channel: channelFromDefine(),
    arch: currentArch(abiName: androidAbi),
  );
  return asset?.downloadUrl;
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
  final l10n = AppLocalizations.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(l10n.tr('common.browserNotOpened')),
        duration: const Duration(seconds: 2),
      ),
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

  String _versionLine(AppLocalizations l10n) {
    final version = _version;
    if (version == null) return '';
    if (version.isEmpty) return l10n.tr('about.versionUnknown');
    return l10n.tr('about.version', {'version': version});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 「检测更新」在 Android 与 Windows 都显示：Android 走侧载包更新，
    // Windows 走安装包/便携包换新。其它平台没有发布形态，不显示。
    final platform = Theme.of(context).platform;
    final canCheck = platform == TargetPlatform.android ||
        platform == TargetPlatform.windows;
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
                    child: Image.asset(kAppIconAsset, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton(
                      tooltip: l10n.tr('common.close'),
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
                      child: Text(
                        l10n.tr('about.projectUrl'),
                        style: const TextStyle(fontSize: 13),
                      ),
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
                            : Text(
                                l10n.tr('about.checkUpdate'),
                                style: const TextStyle(fontSize: 13),
                              ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Text(
                _versionLine(l10n),
                style: const TextStyle(fontSize: 12, color: Color(0xff9aa3a0)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
