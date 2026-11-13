import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:localhand/core/device_info.dart';
import 'package:localhand/core/protocol.dart';
import 'package:localhand/core/secure_channel.dart';
import 'package:localhand/models/session.dart';

/// 收到的连接请求（已解析）。
class IncomingConnectionRequest {
  final String address;
  final String name;
  final String type;
  final String publicKey;
  final String? pairingCode;

  const IncomingConnectionRequest({
    required this.address,
    required this.name,
    required this.type,
    required this.publicKey,
    this.pairingCode,
  });
}

/// 常驻控制服务：接收连接请求、扫码配对与断开通知。
///
/// 使用 TCP，而不是依赖 UDP 单播，因此不会被系统防火墙静默丢弃。
class ControlServer {
  final Future<bool> Function(
      IncomingConnectionRequest request, HandSession session) onRequest;
  final void Function(HandSession session) onSessionReady;
  final void Function(String address) onPeerClosed;

  HttpServer? _server;
  LocalDevice _device = const LocalDevice('未知设备', '未知');

  ControlServer({
    required this.onRequest,
    required this.onSessionReady,
    required this.onPeerClosed,
  });

  Future<void> start() async {
    _device = await loadLocalDevice();
    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        controlPort,
        shared: true,
      );
      _server = server;
      server.listen(_handle);
    } on SocketException {
      // 端口被其他实例占用时保持静默，传输仍可在已有会话中进行。
    }
  }

  void close() {
    _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      switch (request.uri.path) {
        case '/request':
          await _handleRequest(request);
          break;
        case '/close':
          await _handleClose(request);
          break;
        case '/info':
          await _respondJson(request, HttpStatus.ok, {
            'ok': true,
            'name': _device.name,
            'type': _device.type,
          });
          break;
        default:
          await _respondJson(
              request, HttpStatus.notFound, {'ok': false, 'reason': 'not found'});
      }
    } catch (_) {
      try {
        await _respondJson(
            request, HttpStatus.badRequest, {'ok': false, 'reason': 'bad request'});
      } catch (_) {
        // 连接可能已被对方关闭。
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'POST') {
      await _respondJson(request, HttpStatus.methodNotAllowed,
          {'ok': false, 'reason': 'method not allowed'});
      return;
    }

    final body = await _readBody(request, 16 * 1024);
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      data = decoded;
    } catch (_) {
      await _respondJson(request, HttpStatus.badRequest,
          {'ok': false, 'reason': 'invalid request'});
      return;
    }

    final publicKey = data['publicKey'];
    final name = data['name'];
    final type = data['type'];
    if (publicKey is! String || publicKey.isEmpty) {
      await _respondJson(request, HttpStatus.badRequest,
          {'ok': false, 'reason': 'missing public key'});
      return;
    }

    final address = request.connectionInfo?.remoteAddress.address ?? '';
    final incoming = IncomingConnectionRequest(
      address: address,
      name: name is String ? name : '未知设备',
      type: type is String ? type : '未知',
      publicKey: publicKey,
      pairingCode: data['code'] is String ? data['code'] as String : null,
    );

    final localKeys = generateKeyPair();
    Uint8List sessionKey;
    try {
      sessionKey = deriveSessionKey(
        privateKey: localKeys.privateKey,
        localPublicKey: localKeys.publicKey,
        peerPublicKey: publicKey,
      );
    } catch (_) {
      await _respondJson(request, HttpStatus.badRequest,
          {'ok': false, 'reason': 'invalid public key'});
      return;
    }

    final session = HandSession(
      peerAddress: address,
      peerName: incoming.name,
      peerType: incoming.type,
      key: sessionKey,
      initiator: false,
    );

    var accepted = false;
    try {
      accepted = await onRequest(incoming, session)
          .timeout(const Duration(seconds: 62), onTimeout: () => false);
    } catch (_) {
      accepted = false;
    }

    if (!accepted) {
      await _respondJson(request, HttpStatus.ok,
          {'ok': false, 'reason': 'refused'});
      return;
    }

    await _respondJson(request, HttpStatus.ok, {
      'ok': true,
      'name': _device.name,
      'type': _device.type,
      'publicKey': localKeys.publicKey,
    });

    // 响应已经发回发起方，再进入传输页面。
    scheduleMicrotask(() => onSessionReady(session));
  }

  Future<void> _handleClose(HttpRequest request) async {
    await _readBody(request, 4 * 1024);
    final address = request.connectionInfo?.remoteAddress.address ?? '';
    if (address.isNotEmpty) onPeerClosed(address);
    await _respondJson(request, HttpStatus.ok, {'ok': true});
  }

  Future<String> _readBody(HttpRequest request, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > maxBytes) throw const FormatException('body too large');
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<void> _respondJson(
      HttpRequest request, int statusCode, Map<String, dynamic> body) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
