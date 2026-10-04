import 'package:flutter/material.dart';

import '../core/announcement.dart';
import '../core/device_identity.dart';
import '../core/feedback.dart';
import '../core/update_check.dart';
import '../core/vote.dart';
import '../i18n/app_localizations.dart';

/// 用户建议反馈弹窗：正文必填、联系方式选填。
///
/// 提交时现领一张票据（与投票同一套 nonce），失败只提示、不崩。
class FeedbackDialog extends StatefulWidget {
  const FeedbackDialog({super.key});

  @override
  State<FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialog> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _text.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final body = _text.text.trim();
    if (body.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.tr('feedback.empty'))));
      return;
    }
    setState(() => _submitting = true);
    final identity = await collectDeviceIdentity();
    final pkg = await readPackageName();
    var status = await _send(body, identity, pkg);
    if (status == FeedbackStatus.nonceInvalid) {
      status = await _send(body, identity, pkg);
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (status == FeedbackStatus.accepted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.tr('feedback.sent'))));
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.tr('feedback.failed'))));
    }
  }

  Future<FeedbackStatus> _send(
    String body,
    DeviceIdentity identity,
    String pkg,
  ) async {
    final nonce = await fetchNonce();
    if (nonce == null) return FeedbackStatus.failed;
    final deviceId = identity.key.isNotEmpty ? identity.key : newDeviceId();
    return submitFeedback(
      deviceId: deviceId,
      text: body,
      contact: _contact.text.trim(),
      deviceKey: identity.key,
      deviceInfo: identity.info,
      nonce: nonce,
      pkg: pkg,
      version: await readCurrentVersion(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.tr('feedback.title')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: l10n.tr('feedback.body'),
                hintText: l10n.tr('feedback.bodyHint'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contact,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: l10n.tr('feedback.contact'),
                hintText: l10n.tr('feedback.contactHint'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.tr('feedback.cancel')),
        ),
        TextButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.tr('feedback.submit')),
        ),
      ],
    );
  }
}
