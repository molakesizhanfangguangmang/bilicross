import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/models.dart';
import '../core/qr_login.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';

/// 扫码登录页。
///
/// 只做两件事：把二维码画出来、把状态显示出来。拿到 Cookie 后立刻交回调用方，
/// 由账号页走原有的「保存 Cookie → fetchAccount → Cookie → APP Token」流程；
/// 这里不写存储、不碰凭据，页面关掉也不会影响已经保存的登录状态。
class QrLoginPage extends StatefulWidget {
  const QrLoginPage({
    required this.settings,
    required this.onCookie,
    this.poller,
    super.key,
  });

  final AppSettings settings;

  /// 与网页登录一致的出口：回传可直接交给 `AppState.applyCookieText` 的文本。
  final void Function(String cookieText) onCookie;

  /// 测试注入用；为空时按设置自建。
  final QrLoginPoller? poller;

  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  late final QrLoginPoller _poller;
  late final bool _ownsPoller;
  StreamSubscription<QrLoginUpdate>? _subscription;
  QrLoginUpdate _update = const QrLoginUpdate(QrLoginStage.loading);
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _ownsPoller = widget.poller == null;
    _poller = widget.poller ??
        QrLoginPoller(service: QrLoginService(settings: widget.settings));
    _update = _poller.current;
    _subscription = _poller.updates.listen(_onUpdate);
    _poller.start();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    // 只停轮询，不动任何凭据。
    if (_ownsPoller) _poller.dispose();
    super.dispose();
  }

  void _onUpdate(QrLoginUpdate update) {
    if (!mounted) return;
    setState(() => _update = update);
    final cookie = update.cookie;
    if (!update.isSuccess || cookie == null || _handedOff) return;
    _handedOff = true;
    widget.onCookie(cookie.raw);
    // 让「登录成功」露个面再退回账号页，账号页自己会提示写入结果。
    Timer(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  String _stageText(AppLocalizations l10n) {
    switch (_update.stage) {
      case QrLoginStage.loading:
        return l10n.tr('qr.loading');
      case QrLoginStage.waitingScan:
        return l10n.tr('qr.waitingScan');
      case QrLoginStage.waitingConfirm:
        return l10n.tr('qr.waitingConfirm');
      case QrLoginStage.success:
        return l10n.tr('qr.success');
      case QrLoginStage.expired:
        return l10n.tr('qr.expired');
      case QrLoginStage.canceled:
        return l10n.tr('qr.canceled');
      case QrLoginStage.timeout:
        return l10n.tr('qr.timeout');
      case QrLoginStage.networkError:
        return l10n.tr('qr.networkError');
      case QrLoginStage.unavailable:
        if (_update.missingFields.isNotEmpty) {
          return l10n.tr('qr.incomplete', {
            'fields': _update.missingFields.join(' / '),
          });
        }
        return l10n.tr('qr.unavailable');
    }
  }

  int get _stageTone {
    switch (_update.stage) {
      case QrLoginStage.success:
        return 1;
      case QrLoginStage.loading:
      case QrLoginStage.waitingScan:
      case QrLoginStage.waitingConfirm:
        return 2;
      case QrLoginStage.expired:
      case QrLoginStage.timeout:
      case QrLoginStage.networkError:
      case QrLoginStage.unavailable:
        return 3;
      case QrLoginStage.canceled:
        return 0;
    }
  }

  bool get _busy =>
      _update.stage == QrLoginStage.loading || _update.stage == QrLoginStage.success;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tr('qr.title'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: l10n.tr('qr.title'),
              trailing: StateChip(text: _stageText(l10n), tone: _stageTone),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: _qrBox()),
                  const SizedBox(height: 14),
                  Text(
                    _stageText(l10n),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.tr('qr.scanHint'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _poller.refresh(),
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.tr('qr.refresh')),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            _busy || _update.stage == QrLoginStage.canceled
                                ? null
                                : () => _poller.cancel(),
                        icon: const Icon(Icons.close),
                        label: Text(l10n.tr('qr.cancel')),
                      ),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(false),
                        icon: const Icon(Icons.arrow_back),
                        label: Text(l10n.tr('qr.back')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.tr('qr.fallbackHint'),
              style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qrBox() {
    final content = _update.content;
    if (content == null) {
      return Container(
        width: 220,
        height: 220,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xfff2f4f2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: _update.stage == QrLoginStage.loading
            ? const CircularProgressIndicator()
            : const Icon(Icons.qr_code_2, size: 64, color: Color(0xffc9cecc)),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xffd9dedb)),
      ),
      child: QrImageView(
        data: content,
        version: QrVersions.auto,
        size: 200,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      ),
    );
  }
}
