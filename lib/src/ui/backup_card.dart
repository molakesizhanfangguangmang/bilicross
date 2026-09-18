import 'dart:io';
import 'dart:typed_data';

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

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final service = await _service();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: l10n.tr('backup.export'),
        fileName: service.suggestFileName(),
        type: FileType.custom,
        allowedExtensions: const <String>['bcbak'],
      );
      if (path == null) return;
      final bytes = await service.exportBytes();
      await File(path).writeAsBytes(bytes, flush: true);
      // 只提示保存路径，备份内容不进任何日志。
      _toast(l10n.tr('backup.exported', {'path': path}));
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
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: l10n.tr('backup.restore'),
        type: FileType.any,
        allowMultiple: false,
      );
      final file = picked?.files.firstOrNull;
      if (file == null) return;
      final Uint8List bytes;
      final path = file.path;
      if (file.bytes != null) {
        bytes = Uint8List.fromList(file.bytes!);
      } else if (path != null) {
        bytes = await File(path).readAsBytes();
      } else {
        return;
      }

      // 先校验再让用户确认：格式、认证标签、载荷结构都要过。
      final plan = await service.plan(bytes);
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
            style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
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
