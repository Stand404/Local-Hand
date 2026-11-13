import 'dart:convert';

/// 文件传输端口。
const int transferPort = 65001;

/// 连接控制端口（连接请求、断开、扫码配对）。
const int controlPort = 65002;

/// 文件加密分块大小。
const int fileChunkSize = 256 * 1024;

/// 每个分块帧头长度（大端 4 字节密文长度）。
const int frameHeaderLength = 4;

/// 文件级随机前缀长度。
const int fileBaseNonceLength = 8;

/// 二维码中携带的配对信息。
class PairingInfo {
  final String ip;
  final int port;
  final String code;
  final String name;
  final String type;

  const PairingInfo({
    required this.ip,
    required this.port,
    required this.code,
    required this.name,
    required this.type,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'ip': ip,
        'port': port,
        'code': code,
        'name': name,
        'type': type,
      };

  String encode() {
    final payload =
        base64UrlEncode(utf8.encode(jsonEncode(toJson())));
    return 'localhand://pair?d=${Uri.encodeQueryComponent(payload)}';
  }

  static PairingInfo? tryParse(String raw) {
    try {
      var data = raw.trim();
      if (data.startsWith('localhand://pair')) {
        final query = Uri.parse(data).queryParameters['d'];
        if (query != null && query.isNotEmpty) {
          data = utf8.decode(base64Url.decode(query));
        } else {
          // 兼容早期直接拼接 base64 的二维码。
          final encoded = data.split('?').skip(1).join('?');
          data = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
        }
      }
      final map = jsonDecode(data);
      if (map is! Map<String, dynamic>) return null;
      final ip = map['ip'];
      final port = map['port'];
      final code = map['code'];
      if (ip is! String || ip.isEmpty || port is! int || code is! String) {
        return null;
      }
      return PairingInfo(
        ip: ip,
        port: port,
        code: code,
        name: map['name'] is String ? map['name'] as String : '',
        type: map['type'] is String ? map['type'] as String : '',
      );
    } catch (_) {
      return null;
    }
  }
}
