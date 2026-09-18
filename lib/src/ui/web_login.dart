import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../i18n/app_localizations.dart';

/// 内置网页登录：加载 B 站登录页，登录完把 WebView 里的 Cookie 交给调用方。
///
/// WebView 只有 Android 与 iOS 有实现，其它平台由调用方看 [isSupported] 决定是否显示入口。
/// 这里只负责取 Cookie，写入与校验仍走账号页原有那一条路。
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({
    required this.onCookie,
    this.localeCode = kLocaleZhCN,
    super.key,
  });

  final void Function(String cookieText) onCookie;

  /// 跟随应用语言的设置代码，用来决定登录页请求的 Accept-Language。
  /// 只影响页面语言，不参与 Cookie 的读取与回传。
  final String localeCode;

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  /// B 站的 Cookie 挂在 .bilibili.com 上，两个域名都问一次，避免漏掉 HttpOnly 的那几个。
  static const List<String> _probeUrls = <String>[
    'https://www.bilibili.com',
    'https://api.bilibili.com',
  ];

  static const String _loginUrl = 'https://passport.bilibili.com/login';

  late final WebViewController _controller;
  bool _loading = true;
  bool _reading = false;
  bool _handedOff = false;
  bool _statusReady = false;
  String _status = '';

  /// 登录页请求带的 Accept-Language：跟随应用语言，另一种语言放低权重兜底，
  /// 避免服务端完全不认识首选语言时给出更差的结果。
  String get _acceptLanguage => switch (
        AppLocalizations.resolveCode(widget.localeCode)
      ) {
      kLocaleEnUS => 'en-US,en;q=0.9,zh-CN;q=0.8',
      _ => 'zh-CN,zh;q=0.9,en;q=0.8',
    };

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            _readCookies(auto: true);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            final l10n = AppLocalizations.of(context);
            setState(
              () => _status = l10n.tr(
                'webLogin.loadFailed',
                {'error': error.description},
              ),
            );
          },
        ),
      )
      ..loadRequest(
        Uri.parse(_loginUrl),
        headers: {'Accept-Language': _acceptLanguage},
      );
  }

  // initState 里拿不到 Localizations（InheritedWidget 还没挂上），
  // 首次状态文案在 didChangeDependencies 里补。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_statusReady) {
      _statusReady = true;
      _status = AppLocalizations.of(context).tr('webLogin.hint');
    }
  }

  Future<Map<String, String>> _collect() async {
    final manager = WebViewCookieManager();
    final collected = <String, String>{};
    for (final url in _probeUrls) {
      final cookies = await manager.getCookies(domain: Uri.parse(url));
      for (final cookie in cookies) {
        collected[cookie.name] = cookie.value;
      }
    }
    return collected;
  }

  Future<void> _readCookies({bool auto = false}) async {
    if (_reading || _handedOff) return;
    _reading = true;
    try {
      final cookies = await _collect();
      final sessData = cookies['SESSDATA'];
      if (sessData == null || sessData.isEmpty) {
        if (!auto && mounted) {
          setState(() => _status = AppLocalizations.of(context).tr('webLogin.noSessdata'));
        }
        return;
      }
      final text = cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      _handedOff = true;
      widget.onCookie(text);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = AppLocalizations.of(context).tr(
            'webLogin.readFailed',
            {'error': '$error'},
          ),
        );
      }
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('webLogin.title')),
        actions: [
          TextButton(
            onPressed: _reading ? null : () => _readCookies(),
            child: Text(l10n.tr('webLogin.readCookie')),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xfff0f2f0),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 12, color: Color(0xff4d5250)),
            ),
          ),
        ],
      ),
    );
  }
}
