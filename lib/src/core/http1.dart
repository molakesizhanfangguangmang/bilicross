import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一个只够用的 HTTP/1.1 客户端。
///
/// 为什么不用 dart:io 的 HttpClient：`grpc.biliapi.net` 的响应是 chunked，且终止块
/// `0\r\n` 之后还跟着一段 trailer（`bili-status-code`、`bili-trace-id`、`cpu_usage`、
/// `grpc-status`…）。dart:io 的 chunked 解析器只接受 `0\r\n\r\n`，读到 trailer 首字节
/// `b`(98) 时按 CR(13) 校验，抛
/// `HttpException: Failed to parse HTTP, 98 does not match 13`
/// （sdk/lib/_http/http_parser.dart 的 `_expect`）。这段 trailer 关不掉：带
/// `TE: trailers`、不带、`Connection: close` 三种请求头实测都照发。
///
/// 所以这一条请求自己接管 HTTP/1.1：只读状态行与响应头、按 chunked 解正文、见到终止块
/// 即停并把 trailer 收进 [Http1Response.trailers]。不实现 keep-alive、重定向、
/// 认证、cookie 等，用不到的都不写。

class Http1Exception implements Exception {
  const Http1Exception(this.message);

  final String message;

  @override
  String toString() => 'Http1Exception: $message';
}

class Http1Response {
  const Http1Response({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.trailers,
  });

  final int statusCode;

  /// 响应头，键统一小写。
  final Map<String, String> headers;

  final Uint8List body;

  /// chunked 终止块之后的 trailer 段，键统一小写。
  final Map<String, String> trailers;
}

/// 代理目标。设置里按 `host:port` 写，允许带 `http://` / `https://` 前缀。
typedef ProxyTarget = ({String host, int port});

/// 解析代理设置；空串表示不走代理，返回 null。
ProxyTarget? parseProxyTarget(String proxy) {
  var text = proxy.trim();
  if (text.isEmpty) return null;
  final schemeAt = text.indexOf('://');
  if (schemeAt >= 0) {
    final scheme = text.substring(0, schemeAt).toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw Http1Exception('代理只支持 http/https，收到 $scheme');
    }
    text = text.substring(schemeAt + 3);
  }
  final cut = text.lastIndexOf(':');
  if (cut <= 0) throw Http1Exception('代理设置应写成 host:port，收到 $proxy');
  final host = text.substring(0, cut);
  final port = int.tryParse(text.substring(cut + 1));
  if (host.isEmpty || port == null || port <= 0 || port > 65535) {
    throw Http1Exception('代理设置应写成 host:port，收到 $proxy');
  }
  return (host: host, port: port);
}

/// CONNECT 隧道请求（明文发给代理）。
String buildConnectRequest(String host, int port) =>
    'CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n\r\n';

/// 从状态行取状态码。
int parseStatusCode(String statusLine) {
  final parts = statusLine.split(' ');
  if (parts.length < 2) throw Http1Exception('状态行无法解析：$statusLine');
  final code = int.tryParse(parts[1]);
  if (code == null || code < 100 || code > 599) {
    throw Http1Exception('状态行无法解析：$statusLine');
  }
  return code;
}

/// 拼一个 `Connection: close` 的 POST 请求（头 + 正文）。
Uint8List buildRequest({
  required String host,
  required String path,
  required Map<String, String> headers,
  required List<int> body,
}) {
  final builder = BytesBuilder();
  void line(String text) {
    if (text.contains('\r') || text.contains('\n')) {
      throw const Http1Exception('请求头不允许出现换行');
    }
    builder.add(ascii.encode(text));
    builder.add(const <int>[13, 10]);
  }

  line('POST $path HTTP/1.1');
  line('Host: $host');
  headers.forEach((name, value) => line('$name: $value'));
  line('Content-Length: ${body.length}');
  line('Connection: close');
  builder.add(const <int>[13, 10]);
  builder.add(body);
  return builder.takeBytes();
}

/// 发一条 POST 并读完整响应。代理为空则直连。
Future<Http1Response> http1Post({
  required String host,
  required String path,
  required Map<String, String> headers,
  required List<int> body,
  String proxy = '',
  int port = 443,
  Duration connectTimeout = const Duration(seconds: 20),
  Duration readTimeout = const Duration(seconds: 30),
}) async {
  final request = buildRequest(host: host, path: path, headers: headers, body: body);
  final socket = await openTls(
    host: host,
    port: port,
    proxy: proxy,
    connectTimeout: connectTimeout,
  );
  try {
    socket.add(request);
    await socket.flush();
    return await readHttp1Response(socket, readTimeout: readTimeout);
  } finally {
    socket.destroy();
  }
}

/// 直连 TLS，或经 HTTP 代理 CONNECT 后再 TLS。
Future<SecureSocket> openTls({
  required String host,
  int port = 443,
  String proxy = '',
  Duration connectTimeout = const Duration(seconds: 20),
}) async {
  final target = parseProxyTarget(proxy);
  if (target == null) {
    return SecureSocket.connect(
      host,
      port,
      timeout: connectTimeout,
      supportedProtocols: const ['http/1.1'],
    );
  }
  final tunnel = await Socket.connect(target.host, target.port, timeout: connectTimeout);
  try {
    tunnel.add(ascii.encode(buildConnectRequest(host, port)));
    await tunnel.flush();
    await _awaitConnectReply(tunnel, timeout: connectTimeout);
    // dart:io 会把这条 socket 的 raw socket 与订阅一起转交给 TLS 层，接管时用
    // onData 覆盖掉我们的回调（sdk/lib/io/secure_socket.dart 的 _RawSecureSocket
    // 构造里 `_socketSubscription..onData(_eventDispatcher)`），所以这里既不能
    // pause（SDK 会抛 ArgumentError: Subscription passed to TLS upgrade is paused），
    // 也不能在应答之后多读一个字节。
    return await SecureSocket.secure(
      tunnel,
      host: host,
      supportedProtocols: const ['http/1.1'],
    );
  } on Object {
    tunnel.destroy();
    rethrow;
  }
}

/// 读代理的 CONNECT 应答，读到空行为止。订阅留在原处，交给后面的 TLS 升级接管。
Future<void> _awaitConnectReply(Socket socket, {required Duration timeout}) async {
  final buffer = <int>[];
  final done = Completer<void>();
  socket.listen(
    (data) {
      buffer.addAll(data);
      if (!done.isCompleted && _headerEnd(buffer) >= 0) done.complete();
    },
    onError: (Object error) {
      if (!done.isCompleted) {
        done.completeError(Http1Exception('代理隧道出错：$error'));
      }
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(const Http1Exception('代理在应答 CONNECT 之前关闭了连接'));
      }
    },
  );
  try {
    await done.future.timeout(timeout);
  } on TimeoutException {
    throw const Http1Exception('等待代理 CONNECT 应答超时');
  }
  final end = _headerEnd(buffer);
  final lines = latin1.decode(buffer.sublist(0, end)).split('\r\n');
  final code = parseStatusCode(lines.first);
  if (code < 200 || code >= 300) {
    throw Http1Exception('代理拒绝了 CONNECT：${lines.first}');
  }
  if (buffer.length > end + 4) {
    throw Http1Exception(
      '代理在 CONNECT 应答之后多发了 ${buffer.length - end - 4} 字节，无法安全接管 TLS',
    );
  }
}

/// 读一份完整的 HTTP/1.1 响应。抽出来是为了能拿真实抓包的字节喂单测。
Future<Http1Response> readHttp1Response(
  Stream<List<int>> stream, {
  Duration readTimeout = const Duration(seconds: 30),
}) async {
  final source = _ByteSource(stream);
  final statusLine = await source.readLine(readTimeout);
  if (statusLine == null || statusLine.isEmpty) {
    throw const Http1Exception('响应没有状态行');
  }
  final statusCode = parseStatusCode(statusLine);

  final headers = <String, String>{};
  while (true) {
    final line = await source.readLine(readTimeout);
    if (line == null) throw const Http1Exception('响应头没有正常结束');
    if (line.isEmpty) break;
    final cut = line.indexOf(':');
    if (cut <= 0) continue;
    headers[line.substring(0, cut).trim().toLowerCase()] = line.substring(cut + 1).trim();
  }

  final trailers = <String, String>{};
  final Uint8List body;
  final transfer = (headers['transfer-encoding'] ?? '').toLowerCase();
  final length = int.tryParse(headers['content-length'] ?? '');
  if (transfer.contains('chunked')) {
    body = await _readChunked(source, trailers, readTimeout);
  } else if (length != null) {
    body = await source.take(length, readTimeout);
    if (body.length != length) {
      throw const Http1Exception('正文短于 Content-Length');
    }
  } else {
    body = await source.takeRest(readTimeout);
  }

  final encoding = (headers['content-encoding'] ?? '').toLowerCase();
  return Http1Response(
    statusCode: statusCode,
    headers: headers,
    body: encoding == 'gzip' ? Uint8List.fromList(gzip.decode(body)) : body,
    trailers: trailers,
  );
}

Future<Uint8List> _readChunked(
  _ByteSource source,
  Map<String, String> trailers,
  Duration readTimeout,
) async {
  final builder = BytesBuilder(copy: false);
  while (true) {
    final line = await source.readLine(readTimeout);
    if (line == null) throw const Http1Exception('chunked 正文在长度行处中断');
    final size = int.tryParse(line.split(';').first.trim(), radix: 16);
    if (size == null) throw Http1Exception('chunked 长度行无法解析：$line');
    if (size == 0) {
      // 终止块之后是 trailer 段，一直读到空行；直接 EOF 也算正常结束。
      while (true) {
        final item = await source.readLine(readTimeout);
        if (item == null || item.isEmpty) break;
        final cut = item.indexOf(':');
        if (cut > 0) {
          trailers[item.substring(0, cut).trim().toLowerCase()] = item.substring(cut + 1).trim();
        }
      }
      break;
    }
    final chunk = await source.take(size, readTimeout);
    if (chunk.length != size) throw const Http1Exception('chunked 分块不完整');
    builder.add(chunk);
    await source.readLine(readTimeout); // 分块末尾的 CRLF
  }
  return builder.takeBytes();
}

/// `\r\n\r\n` 的位置，找不到返回 -1。
int _headerEnd(List<int> data) {
  for (var i = 0; i + 3 < data.length; i++) {
    if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// 按需拉取的字节源：不整段缓存，读到哪里算哪里。
class _ByteSource {
  _ByteSource(Stream<List<int>> stream) : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  List<int> _buffer = const <int>[];
  int _start = 0;
  bool _eof = false;

  Future<bool> _pull(Duration timeout) async {
    if (_eof) return false;
    final bool hasNext;
    try {
      hasNext = await _iterator.moveNext().timeout(timeout);
    } on TimeoutException {
      throw const Http1Exception('读取响应超时');
    }
    if (!hasNext) {
      _eof = true;
      return false;
    }
    _buffer = _iterator.current;
    _start = 0;
    return true;
  }

  Future<int?> _byte(Duration timeout) async {
    while (_start >= _buffer.length) {
      if (!await _pull(timeout)) return null;
    }
    return _buffer[_start++];
  }

  /// 读一行，返回不含 CRLF 的内容；EOF 且无任何字节时返回 null。
  Future<String?> readLine(Duration timeout) async {
    final bytes = <int>[];
    while (true) {
      final byte = await _byte(timeout);
      if (byte == null) return bytes.isEmpty ? null : latin1.decode(bytes);
      if (byte == 0x0a) {
        if (bytes.isNotEmpty && bytes.last == 0x0d) bytes.removeLast();
        return latin1.decode(bytes);
      }
      bytes.add(byte);
    }
  }

  Future<Uint8List> take(int count, Duration timeout) async {
    final builder = BytesBuilder(copy: false);
    var remaining = count;
    while (remaining > 0) {
      if (_start >= _buffer.length) {
        if (!await _pull(timeout)) break;
        continue;
      }
      final available = _buffer.length - _start;
      final size = available < remaining ? available : remaining;
      builder.add(Uint8List.fromList(_buffer.sublist(_start, _start + size)));
      _start += size;
      remaining -= size;
    }
    return builder.takeBytes();
  }

  Future<Uint8List> takeRest(Duration timeout) async {
    final builder = BytesBuilder(copy: false);
    while (true) {
      if (_start >= _buffer.length) {
        if (!await _pull(timeout)) break;
        continue;
      }
      builder.add(Uint8List.fromList(_buffer.sublist(_start)));
      _start = _buffer.length;
    }
    return builder.takeBytes();
  }
}
