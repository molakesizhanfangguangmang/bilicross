import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../core/bili_api.dart';
import '../i18n/app_localizations.dart';
import 'qr_login_page.dart';
import 'web_login.dart';
import '../platform/windows/web_login_page.dart';
import 'widgets.dart';
import './palette.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cookie = state.cookie;
        final webLoginSupported =
            Platform.isAndroid || Platform.isIOS || Platform.isWindows;
        return PageFrame(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                title: 'WEB Cookie',
                trailing: StateChip(
                  text: cookie.isEmpty
                      ? l10n.tr('account.cookieMissing')
                      : (cookie.isComplete
                          ? l10n.tr('account.cookieComplete')
                          : l10n.tr('account.cookieIncomplete')),
                  tone: cookie.isEmpty ? 0 : (cookie.isComplete ? 1 : 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoLine(
                      label: 'SESSDATA',
                      value: cookie.isEmpty ? '—' : cookie.maskedSessData,
                    ),
                    InfoLine(
                      label: 'bili_jct',
                      value: cookie.biliJct.isEmpty ? '—' : l10n.tr('account.written'),
                    ),
                    InfoLine(
                      label: 'DedeUserID',
                      value: cookie.dedeUserId.isEmpty ? '—' : l10n.tr('account.written'),
                    ),
                    const SizedBox(height: 12),
                    // 取凭据的两个入口并排：扫码（首选）与网页登录（兜底）。
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _qrLogin(context),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: Text(l10n.tr('qr.entry')),
                        ),
                        if (webLoginSupported)
                          OutlinedButton.icon(
                            onPressed: () => _webLogin(context),
                            icon: const Icon(Icons.public),
                            label: Text(l10n.tr('account.webLogin')),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 手动补齐：粘贴或导入 cookie.txt。
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _pasteCookie(context),
                          icon: const Icon(Icons.paste),
                          label: Text(l10n.tr('account.pasteCookie')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _importCookieFile(context),
                          icon: const Icon(Icons.file_open),
                          label: Text(l10n.tr('account.importCookie')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 状态维护放最下面。
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _refresh(context),
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.tr('account.checkStatus')),
                        ),
                        OutlinedButton.icon(
                          onPressed: cookie.isEmpty
                              ? null
                              : () => state.clearCookie(),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(l10n.tr('account.clear')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      webLoginSupported
                          ? l10n.tr('account.webLoginHint')
                          : l10n.tr('account.noBrowserHint'),
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                    const SizedBox(height: 6),
                    // 两个入口都摆在明面上：扫码为主，网页/粘贴/导入为兜底。
                    Text(
                      l10n.tr('qr.entriesHint'),
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: l10n.tr('account.webStatusTitle'),
                trailing: state.busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoLine(
                      label: l10n.tr('account.loggedIn'),
                      value: state.account.loggedIn
                          ? l10n.tr('common.yes')
                          : l10n.tr('common.no'),
                    ),
                    InfoLine(
                      label: l10n.tr('account.nickname'),
                      value: state.account.uname.isEmpty ? '—' : state.account.uname,
                    ),
                    InfoLine(
                      label: 'UID',
                      value: state.account.mid == 0 ? '—' : '${state.account.mid}',
                    ),
                    InfoLine(label: l10n.tr('account.vip'), value: state.account.vipLabel(l10n)),
                    InfoLine(label: l10n.tr('account.message'), value: state.account.message),
                    const SizedBox(height: 6),
                    Text(
                      l10n.tr('account.webOnlyHint'),
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'APP Token',
                trailing: StateChip(
                  text: state.token == null
                      ? l10n.tr('account.tokenMissing')
                      : l10n.tr('account.tokenReady'),
                  tone: state.token == null ? 0 : 1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoLine(label: 'Token', value: state.token?.masked ?? '—'),
                    InfoLine(
                      label: l10n.tr('account.expiresAt'),
                      value: state.token == null || state.token!.expiresIn == 0
                          ? '—'
                          : DateTime.fromMillisecondsSinceEpoch(state.token!.expiresAtMs)
                              .toLocal()
                              .toString()
                              .split('.')
                              .first,
                    ),
                    if (state.authStatus.isNotEmpty)
                      InfoLine(label: l10n.tr('account.auth'), value: state.authStatus),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: state.pendingAuth != null || cookie.isEmpty
                              ? null
                              : () => _startAuth(context),
                          icon: const Icon(Icons.open_in_browser),
                          label: Text(l10n.tr('account.openAuth')),
                        ),
                        if (state.pendingAuth != null)
                          OutlinedButton(
                            onPressed: () => state.cancelAppAuth(),
                            child: Text(l10n.tr('account.cancelAuth')),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.tr('account.authHint'),
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _refresh(BuildContext context) async {
    await state.refreshAccount();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(state.account.message)),
    );
  }

  /// 扫码登录：页面只负责拿到 Cookie 文本，后面的保存与校验跟网页登录同一条路。
  Future<void> _qrLogin(BuildContext context) async {
    String? captured;
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (routeContext) => QrLoginPage(
          settings: state.settings,
          onCookie: (text) => captured = text,
        ),
      ),
    );
    final text = captured;
    if (text == null || !context.mounted) return;
    await _apply(context, text);
  }

  Future<void> _webLogin(BuildContext context) async {
    String? captured;
    final Widget page;
    if (Platform.isWindows) {
      page = WindowsWebLoginPage(
        onCookie: (text) => captured = text,
        localeCode: state.settings.localeCode,
      );
    } else {
      page = WebLoginPage(
        onCookie: (text) => captured = text,
        localeCode: state.settings.localeCode,
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(builder: (routeContext) => page),
    );
    final text = captured;
    if (text == null || !context.mounted) return;
    await _apply(context, text);
  }

  Future<void> _pasteCookie(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tr('account.pasteCookie')),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 6,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'SESSDATA=...; bili_jct=...; DedeUserID=...',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.tr('common.save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    if (!context.mounted) return;
    await _apply(context, text);
  }

  Future<void> _importCookieFile(BuildContext context) async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final bytes = await files.first.readAsBytes();
    if (bytes.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).tr('account.emptyFile'))),
      );
      return;
    }
    if (!context.mounted) return;
    await _apply(context, utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _apply(BuildContext context, String text) async {
    final l10n = AppLocalizations.of(context);
    try {
      await state.applyCookieText(text);
    } on BiliException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          state.notice.isEmpty ? l10n.tr('account.cookieWritten') : state.notice,
        ),
      ),
    );
  }

  Future<void> _startAuth(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      await state.startAppAuth();
    } on BiliException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
      return;
    }
    final url = state.pendingAuth?.url;
    if (url == null) return;
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          launched
              ? l10n.tr('account.authPageOpened')
              : l10n.tr('account.browserFailed'),
        ),
      ),
    );
  }
}
