import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localhand/core/device_info.dart';
import 'package:localhand/core/protocol.dart';
import 'package:localhand/core/secure_channel.dart';
import 'package:localhand/models/session.dart';

class ConnectOutcome {
  final HandSession? session;
  final String error;

  const ConnectOutcome.success(this.session) : error = '';
  const ConnectOutcome.failure(this.error) : session = null;

  bool get ok => session != null;
}

/// 发起连接请求。等待对方确认的最长时间为 60 秒。
class ControlClient {
  static Future<ConnectOutcome> request({
    required String address,
    String? pairingCode,
  }) async {
    final local = await loadLocalDevice();
    final keys = generateKeyPair();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 65);

    try {
      final request = await client
          .postUrl(Uri.parse('http://$address:$controlPort/request'))
          .timeout(const Duration(seconds: 6));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'v': 1,
        'name': local.name,
        'type': local.type,
        'publicKey': keys.publicKey,
        if (pairingCode != null) 'code': pairingCode,
      }));

      final response =
          await request.close().timeout(const Duration(seconds: 65));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != HttpStatus.ok) {
        return const ConnectOutcome.failure('对方的连接服务异常，请重试');
      }

      Map<String, dynamic> data;
      try {
        data = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        return const ConnectOutcome.failure('对方返回了无法识别的数据');
      }

      if (data['ok'] != true) {
        return ConnectOutcome.failure(
            data['reason'] == 'busy' ? '对方正在传输中，请稍后再试' : '对方拒绝了连接');
      }

      final peerPublicKey = data['publicKey'];
      if (peerPublicKey is! String || peerPublicKey.isEmpty) {
        return const ConnectOutcome.failure('对方未返回加密公钥');
      }

      final sessionKey = deriveSessionKey(
        privateKey: keys.privateKey,
        localPublicKey: keys.publicKey,
        peerPublicKey: peerPublicKey,
      );

      return ConnectOutcome.success(HandSession(
        peerAddress: address,
        peerName: data['name'] is String ? data['name'] as String : '未知设备',
        peerType: data['type'] is String ? data['type'] as String : '未知',
        key: sessionKey,
        initiator: true,
      ));
    } on TimeoutException {
      return const ConnectOutcome.failure(
          '对方未响应。请确认两台设备在同一局域网，或改用扫码配对');
    } on SocketException {
      return const ConnectOutcome.failure(
          '无法连接到对方。请检查防火墙是否允许 Local Hand 通信，或改用扫码配对');
    } catch (_) {
      return const ConnectOutcome.failure('连接失败，请重试或改用扫码配对');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> close(String address) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .postUrl(Uri.parse('http://$address:$controlPort/close'))
          .timeout(const Duration(seconds: 2));
      request.write('{}');
      final response = await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 对方可能已经离线。
    } finally {
      client.close(force: true);
    }
  }
}
