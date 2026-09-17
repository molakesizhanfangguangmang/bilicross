import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 内置网页登录：加载 B 站登录页，登录完把 WebView 里的 Cookie 交给调用方。
///
/// WebView 只有 Android 与 iOS 有实现，其它平台由调用方看 [isSupported] 决定是否显示入口。
/// 这里只负责取 Cookie，写入与校验仍走账号页原有那一条路。
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({required this.onCookie, super.key});

  final void Function(String cookieText) onCookie;

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
  String _status = '登录完成后会自动读取；也可以点右上角手动读取。';

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
            setState(() => _status = '页面加载失败：${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(_loginUrl));
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
          setState(() => _status = '还没读到 SESSDATA，先在页面里完成登录。');
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
        setState(() => _status = '读取 Cookie 失败：$error');
      }
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网页登录'),
        actions: [
          TextButton(
            onPressed: _reading ? null : () => _readCookies(),
            child: const Text('读取 Cookie'),
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
