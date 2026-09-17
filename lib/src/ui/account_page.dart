import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../core/bili_api.dart';
import 'widgets.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cookie = state.cookie;
        return PageFrame(
          title: '账号与授权',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                title: 'WEB Cookie',
                trailing: StateChip(
                  text: cookie.isEmpty ? '未配置' : (cookie.isComplete ? '字段齐全' : '字段不全'),
                  tone: cookie.isEmpty ? 0 : (cookie.isComplete ? 1 : 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoLine(
                      label: 'SESSDATA',
                      value: cookie.isEmpty ? '—' : cookie.maskedSessData,
                    ),
                    InfoLine(label: 'bili_jct', value: cookie.biliJct.isEmpty ? '—' : '已写入'),
                    InfoLine(label: 'DedeUserID', value: cookie.dedeUserId.isEmpty ? '—' : '已写入'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _pasteCookie(context),
                          icon: const Icon(Icons.paste),
                          label: const Text('粘贴 Cookie'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _importCookieFile(context),
                          icon: const Icon(Icons.file_open),
                          label: const Text('导入 cookie.txt'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _refresh(context),
                          icon: const Icon(Icons.refresh),
                          label: const Text('检测状态'),
                        ),
                        OutlinedButton.icon(
                          onPressed: cookie.isEmpty ? null : () => state.clearCookie(),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('清除'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '嵌入网页登录尚未接入，本版本请用粘贴或导入 cookie.txt。',
                      style: TextStyle(fontSize: 12, color: Color(0xff8a5b4a)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'WEB 账号状态',
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
                    InfoLine(label: '登录', value: state.account.loggedIn ? '是' : '否'),
                    InfoLine(
                      label: '昵称',
                      value: state.account.uname.isEmpty ? '—' : state.account.uname,
                    ),
                    InfoLine(
                      label: 'UID',
                      value: state.account.mid == 0 ? '—' : '${state.account.mid}',
                    ),
                    InfoLine(label: '大会员', value: state.account.vipLabel),
                    InfoLine(label: '返回', value: state.account.message),
                    const SizedBox(height: 6),
                    const Text(
                      '这里的登录状态来自 WEB Cookie，只代表网页账号，不代表 APP Token 可用。',
                      style: TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'APP Token',
                trailing: StateChip(
                  text: state.token == null ? '未获取' : '已获取',
                  tone: state.token == null ? 0 : 1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoLine(label: 'Token', value: state.token?.masked ?? '—'),
                    InfoLine(
                      label: '过期时间',
                      value: state.token == null || state.token!.expiresIn == 0
                          ? '—'
                          : DateTime.fromMillisecondsSinceEpoch(state.token!.expiresAtMs)
                              .toLocal()
                              .toString()
                              .split('.')
                              .first,
                    ),
                    if (state.authStatus.isNotEmpty) InfoLine(label: '授权', value: state.authStatus),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: state.pendingAuth != null || cookie.isEmpty
                              ? null
                              : () => _startAuth(context),
                          icon: const Icon(Icons.open_in_browser),
                          label: const Text('打开 APP 授权'),
                        ),
                        if (state.pendingAuth != null)
                          OutlinedButton(
                            onPressed: () => state.cancelAppAuth(),
                            child: const Text('取消授权'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '授权在系统浏览器里完成：打开链接后用手机 App 扫码确认，应用每 2 秒轮询一次，5 分钟未确认即超时。',
                      style: TextStyle(fontSize: 12, color: Color(0xff6d716f)),
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

  Future<void> _pasteCookie(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴 Cookie'),
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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('写入'),
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
        const SnackBar(content: Text('文件内容为空')),
      );
      return;
    }
    if (!context.mounted) return;
    await _apply(context, utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _apply(BuildContext context, String text) async {
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
      SnackBar(content: Text(state.notice.isEmpty ? '已写入 Cookie' : state.notice)),
    );
  }

  Future<void> _startAuth(BuildContext context) async {
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
      SnackBar(content: Text(launched ? '已打开授权页面，请用手机 App 确认' : '浏览器未打开，请手动访问授权链接')),
    );
  }
}
