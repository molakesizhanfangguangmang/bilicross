import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';
import '../core/backup/backup_codec.dart';
import '../core/backup/backup_format.dart';
import '../core/backup/backup_key_ring.dart';
import '../core/backup/backup_service.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';
import './palette.dart';

/// 「备份与恢复」卡片，只在 Windows 显示（安装版与便携版互相恢复）。
///
/// 加密与恢复全部交给 core 层的 [BackupService] / [BackupCodec]，界面只做三件事：
/// 让用户选文件、把备份的来源信息摆清楚、拿到二次确认再执行。
/// 任何路径都不打印备份内容、Cookie、Token 或密钥 —— 日志与提示里只有文件名与计数。
class BackupCard extends StatefulWidget {
  const BackupCard({required this.state, super.key});

  final AppState state;

  @override
  State<BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends State<BackupCard> {
  bool _busy = false;

  Future<BackupService> _service() async {
    final info = await PackageInfo.fromPlatform();
    return BackupService(
      codec: BackupCodec(keyRing: BackupKeyRing.fromEnvironment()),
      root: widget.state.store.root,
      appVersion: info.version,
      platform: Platform.operatingSystem,
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _showError(String text) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tr('backup.failed', {'error': text})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.tr('common.close')),
          ),
        ],
      ),
    );
  }

  /// 口令输入框。返回 null 表示用户取消。
///
/// [confirm] 为 true 时要求输两遍并比对（导出用）—— 口令打错就等于把备份作废，
/// 必须让用户确认一遍。
Future<String?> _askPassphrase(
  BuildContext context, {
  required String title,
  required String hint,
  required bool confirm,
}) async {
  final l10n = AppLocalizations.of(context);
  final first = TextEditingController();
  final second = TextEditingController();
  final error = ValueNotifier<String?>(null);

  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(hint, style: const TextStyle(fontSize: 12, color: kTextMuted)),
          const SizedBox(height: 12),
          TextField(
            controller: first,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(labelText: l10n.tr('backup.passphrase')),
          ),
          if (confirm) ...<Widget>[
            const SizedBox(height: 10),
            TextField(
              controller: second,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.tr('backup.passphraseAgain'),
              ),
            ),
          ],
          ValueListenableBuilder<String?>(
            valueListenable: error,
            builder: (context, message, _) => message == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      message,
                      style: const TextStyle(fontSize: 12, color: kDanger),
                    ),
                  ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () {
            final value = first.text.trim();
            if (value.length < kBackupMinPassphraseLength) {
              error.value = l10n.tr('backup.passphraseTooShort', {
                'count': '$kBackupMinPassphraseLength',
              });
              return;
            }
            if (confirm && value != second.text.trim()) {
              error.value = l10n.tr('backup.passphraseMismatch');
              return;
            }
            Navigator.of(dialogContext).pop(value);
          },
          child: Text(l10n.tr('common.ok')),
        ),
      ],
    ),
  );

  first.dispose();
  second.dispose();
  error.dispose();
  return result;
}

/// 同一天导出多次时不覆盖前一份：撞名就加 -2、-3…
  ///
  /// 文件名只带日期（`BiliCross-Backup-YYYYMMDD.bcbak`），当天再导一次会撞上。
  File _uniqueTarget(String dir, String fileName) {
    final base = fileName.replaceAll(RegExp(r'\.bcbak$'), '');
    var candidate = File('$dir${Platform.pathSeparator}$fileName');
    var n = 1;
    while (candidate.existsSync()) {
      n += 1;
      candidate = File('$dir${Platform.pathSeparator}$base-$n.bcbak');
    }
    return candidate;
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final service = await _service();
      // ⚠️ await 之后 context 可能已经失效，用之前先确认还挂着。
      if (!mounted) return;

      // ⚠️ 口令是必填的，而且要输两遍 ——
      // 口令打错 = 这份备份以后再也打不开，必须让用户确认一遍。
      final passphrase = await _askPassphrase(
        context,
        title: l10n.tr('backup.passphraseSetTitle'),
        hint: l10n.tr('backup.passphraseSetHint'),
        confirm: true,
      );
      if (passphrase == null) return;

      final bytes = await service.exportBytes(passphrase: passphrase);

      // ⚠️ 安卓：直接写进下载目录（跟视频放在一起），不走系统选择器 ——
      // 系统选择器对自定义扩展名不友好，而且"另存为"多一步。
      // 桌面端保留"另存为"，那里用户确实需要选位置（U 盘、网盘同步目录等）。
      if (Platform.isAndroid) {
        final dir = widget.state.settings.downloadDir.trim();
        if (dir.isEmpty) {
          await _showError(l10n.tr('backup.noDownloadDir'));
          return;
        }
        final target = _uniqueTarget(dir, service.suggestFileName());
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
        // 只提示保存路径，备份内容不进任何日志。
        _toast(l10n.tr('backup.exported', {'path': target.path}));
        return;
      }

      // 插件直接把字节写到用户选的位置，返回目标 Uri；取消时为 null。
      final target = await FilePicker.saveFile(
        bytes: bytes,
        dialogTitle: l10n.tr('backup.export'),
        fileName: service.suggestFileName(),
        type: FileType.custom,
        allowedExtensions: const <String>['bcbak'],
      );
      if (target == null) return;
      // 只提示保存路径，备份内容不进任何日志。
      _toast(l10n.tr('backup.exported', {'path': target.toFilePath()}));
    } on BackupKeyException catch (error) {
      await _showError(error.message);
    } catch (error) {
      await _showError('${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final service = await _service();
      final picked = await FilePicker.pickFiles(
        dialogTitle: l10n.tr('backup.restore'),
        // ⚠️ 安卓是按 MIME 过滤的，`.bcbak` 是自定义扩展名 —— 用 custom +
        // allowedExtensions 很可能**什么都选不了**。放宽成任意文件，
        // 靠备份文件自己的 magic（BCBAKBK1）把选错的文件拦下来。
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid ? null : const <String>['bcbak'],
      );
      final file = picked.firstOrNull;
      if (file == null) return;
      final path = file.path;
      if (path == null) return;
      final bytes = await File(path).readAsBytes();

      // 先只读头部：判断这份备份要不要口令。老格式（v1）不需要，直接往下走。
      final header = service.inspect(bytes);
      String? passphrase;
      if (header.usesPassphrase) {
        if (!mounted) return;
        passphrase = await _askPassphrase(
          context,
          title: l10n.tr('backup.passphraseAskTitle'),
          hint: l10n.tr('backup.passphraseAskHint'),
          confirm: false,
        );
        if (passphrase == null) return;
      }

      // 先校验再让用户确认：格式、认证标签、载荷结构都要过。
      final plan = await service.plan(bytes, passphrase: passphrase);
      final confirmed = await _confirm(plan);
      if (confirmed != true) return;

      final outcome = await service.restore(plan);
      await widget.state.reloadAfterRestore();
      _toast(
        l10n.tr('backup.restored', {'count': '${outcome.restoredFiles.length}'}),
      );
      if (outcome.pendingTaskPaths.isNotEmpty) {
        _toast(
          l10n.tr('backup.pending', {'count': '${outcome.pendingTaskPaths.length}'}),
        );
      }
    } on BackupKeyException catch (error) {
      await _showError(error.message);
    } on BackupAuthenticationException catch (error) {
      await _showError('$error');
    } on BackupFormatException catch (error) {
      await _showError(error.message);
    } on BackupRestoreException catch (error) {
      await _showError(error.message);
    } catch (error) {
      await _showError('${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 二次确认：把来源与「会覆盖、但先留回滚备份」讲清楚，用户取消就什么都不做。
  Future<bool?> _confirm(BackupRestorePlan plan) {
    final l10n = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tr('backup.confirmTitle')),
        content: Text(
          l10n.tr('backup.confirmBody', {'source': plan.describeSource()}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.tr('backup.confirmOk')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      title: l10n.tr('settings.backup'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.tr('backup.hint'),
            style: const TextStyle(fontSize: 12, color: kTextMuted),
          ),
          const SizedBox(height: 10),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.ios_share_outlined),
                  label: Text(l10n.tr('backup.export')),
                ),
                OutlinedButton.icon(
                  onPressed: _restore,
                  icon: const Icon(Icons.settings_backup_restore),
                  label: Text(l10n.tr('backup.restore')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
