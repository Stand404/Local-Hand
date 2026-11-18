import 'dart:convert';
import 'dart:io';

import 'package:localhand/core/device_info.dart';
import 'package:localhand/core/protocol.dart';
import 'package:localhand/models/friends.dart';

// 定义回调类型的别名
typedef FriendCallback = Function(FriendMsgType type, String message);

final InternetAddress _mDnsAddressIPv4 = InternetAddress('224.0.0.251');
const int _legacyDiscoveryPort = 65000;

bool _hasMatch(String value, String pattern) {
  // ignore: unnecessary_null_comparison
  return (value == null) ? false : RegExp(pattern).hasMatch(value);
}

/// 抄的getx
extension IpString on String {
  bool get isIPv4 =>
      _hasMatch(this, r'^(?:(?:^|\.)(?:2(?:5[0-5]|[0-4]\d)|1?\d?\d)){4}$');
}

/// 通过组播 + 广播让局域网内设备互相发现。
///
/// 连接请求本身不再走 UDP，而是由控制通道通过 TCP 完成，
/// 避免 UDP 单播被防火墙/多网卡路由丢弃导致“点了连接对方没反应”。
class Multicast {
  final int? port;
  RawDatagramSocket? _socket;
  RawDatagramSocket? _listenSocket;
  RawDatagramSocket? _legacySocket;
  int _listenPort = discoveryPort;
  final FriendCallback? friendCallback;
  final int Function()? controlPortProvider;
  bool _closed = false;
  late final Future<void> _ready;

  Multicast({
    this.port,
    this.friendCallback,
    this.controlPortProvider,
  }) {
    _ready = _init();
  }

  List<int> get _targetPorts =>
      port != null ? <int>[port!] : discoveryPorts;

  int get listenPort => _listenPort;

  Future<void> _init() async {
    await instanceSend();
    await _receiveBoardCast();
    unawaitedSearch();
  }

  void unawaitedSearch() {
    search().catchError((_) {});
  }

  void close() {
    _closed = true;
    _socket?.close();
    _socket = null;
    _listenSocket?.close();
    _listenSocket = null;
    _legacySocket?.close();
    _legacySocket = null;
  }

  /// 接收udp广播消息
  Future<void> _receiveBoardCast() async {
    for (final candidate in _targetPorts) {
      if (_closed) return;
      final socket = await _bindListener(candidate);
      if (socket != null) {
        _listenSocket = socket;
        _listenPort = candidate;
        break;
      }
    }
    if (_closed) return;
    // 尽量同时监听旧版 65000，兼容尚未升级的 1.1.0 设备；被占用/保留则忽略。
    if (port == null && _listenPort != _legacyDiscoveryPort) {
      _legacySocket =
          await _bindListener(_legacyDiscoveryPort, legacyOnly: true);
    }
  }

  Future<RawDatagramSocket?> _bindListener(int bindPort,
      {bool legacyOnly = false}) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        bindPort,
        reuseAddress: true,
        reusePort: false,
        ttl: 255,
      );
      if (_closed) {
        socket.close();
        return null;
      }
      var joined = false;
      try {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          type: InternetAddressType.IPv4,
        );
        for (final interface in interfaces) {
          try {
            socket.joinMulticast(_mDnsAddressIPv4, interface);
            joined = true;
          } catch (_) {
            // 某些虚拟网卡不支持组播，跳过即可。
          }
        }
      } catch (_) {}
      if (!joined) {
        try {
          socket.joinMulticast(_mDnsAddressIPv4);
        } catch (_) {}
      }
      socket.broadcastEnabled = true;
      socket.readEventsEnabled = true;
      socket.listen((RawSocketEvent rawSocketEvent) {
        final Datagram? datagram = socket.receive();
        if (datagram == null) return;

        final message = utf8.decode(datagram.data, allowMalformed: true);
        final sourceAddress = datagram.address.address;
        _handleMessage(message, sourceAddress, legacyOnly: legacyOnly);
      });
      return socket;
    } on SocketException {
      return null;
    }
  }

  Future<void> _handleMessage(String message, String sourceAddress,
      {bool legacyOnly = false}) async {
    if (_closed || await _isSelf(sourceAddress)) return;

    if (message == 'Stand') {
      // 兼容旧版本：收到扫描请求后单播回应自己的设备信息。
      _sendDeviceInfo(sourceAddress, targetPort: _legacyDiscoveryPort);
      return;
    }

    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      final name = decoded['deviceName'];
      final type = decoded['deviceType'];
      if (name is! String || type is! String) return;

      // 新版广播会同时发往主端口与 65000，主监听已处理时跳过兼容监听的重复包。
      if (legacyOnly && decoded['discoveryPort'] != null) return;

      final peerControlPort =
          parseValidPort(decoded['controlPort']) ?? controlPort;
      final peerDiscoveryPort =
          parseValidPort(decoded['discoveryPort']) ?? _legacyDiscoveryPort;

      // 地址使用数据包真实来源，而不是对方自报的 IP：
      // 手机同时开启移动网络/VPN 时自报 IP 可能不可达。
      friendCallback?.call(
          FriendMsgType.message,
          jsonEncode({
            'address': sourceAddress,
            'deviceName': name,
            'deviceType': type,
            'controlPort': peerControlPort,
          }));

      if (decoded['kind'] == 'discover') {
        _sendDeviceInfo(sourceAddress, targetPort: peerDiscoveryPort);
      }
    } catch (_) {
      // 忽略非本协议的数据包。
    }
  }

  Future<bool> _isSelf(String address) async {
    for (final host in await _localAddress()) {
      if (address == host) return true;
    }
    return false;
  }

  Future<void> _sendDeviceInfo(String address, {int? targetPort}) async {
    final device = await loadLocalDevice();
    final localAddress = await loadLocalHost();
    send(
      jsonEncode({
        'kind': 'info',
        'address': localAddress,
        'deviceName': device.name,
        'deviceType': device.type,
        'controlPort': controlPortProvider?.call() ?? controlPort,
        'discoveryPort': _listenPort,
      }),
      address,
      targetPort: targetPort ?? _listenPort,
    );
  }

  /// 选择最可能可达的局域网 IPv4 地址。
  Future<String> loadLocalHost() async {
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    final candidates = <MapEntry<String, String>>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      for (final address in interface.addresses) {
        final ip = address.address;
        if (ip.startsWith('127.')) continue;
        candidates.add(MapEntry(name, ip));
      }
    }
    if (candidates.isEmpty) return '';

    int score(MapEntry<String, String> entry) {
      var value = 0;
      final ip = entry.value;
      final name = entry.key;
      if (_isPrivateIpv4(ip)) value += 100;
      if (RegExp(r'^(wlan|wifi|wl|en|eth)').hasMatch(name)) value += 50;
      if (RegExp(
              r'(tun|tap|ppp|rmnet|clat|dummy|vpn|meta|clash|mihomo|wireguard|tailscale)')
          .hasMatch(name)) {
        value -= 200;
      }
      if (ip.startsWith('169.254.')) value -= 300;
      return value;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.first.value;
  }

  bool _isPrivateIpv4(String ip) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.contains(null)) return false;
    final first = parts[0]!;
    final second = parts[1]!;
    if (first == 10) return true;
    if (first == 192 && second == 168) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    return false;
  }

  // 发送器
  Future<void> instanceSend() async {
    if (_closed || _socket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        ttl: 255,
      );
      if (_closed) {
        socket.close();
        return;
      }
      socket.broadcastEnabled = true;
      socket.readEventsEnabled = true;
      _socket = socket;
    } on SocketException {
      // 绑定失败时保持静默。
    }
  }

  /// 单独给一个人发
  void send(String msg, String address, {int? targetPort}) {
    final socket = _socket;
    if (_closed || socket == null) return;
    try {
      socket.send(utf8.encode(msg), InternetAddress(address),
          targetPort ?? _listenPort);
    } catch (_) {
      // 地址不可达时忽略。
    }
  }

  /// 扫描局域网设备。连发三次以提高到达率。
  Future<void> search() async {
    await _ready;
    if (_closed) return;
    final device = await loadLocalDevice();
    final localAddress = await loadLocalHost();
    final payload = jsonEncode({
      'kind': 'discover',
      'address': localAddress,
      'deviceName': device.name,
      'deviceType': device.type,
      'controlPort': controlPortProvider?.call() ?? controlPort,
      'discoveryPort': _listenPort,
    });
    for (var i = 0; i < 3; i++) {
      if (_closed) return;
      await boardcast(payload);
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  // 广播
  Future<void> boardcast(String msg) async {
    final socket = _socket;
    if (_closed || socket == null) return;
    final dataList = utf8.encode(msg);
    final addresses = await _localAddress();
    final broadcasts = <InternetAddress>[_mDnsAddressIPv4];
    for (final addr in addresses) {
      final parts = addr.split('.');
      if (parts.length != 4) continue;
      parts.removeLast();
      broadcasts.add(InternetAddress('${parts.join('.')}.255'));
    }
    for (final target in broadcasts) {
      for (final targetPort in _targetPorts) {
        try {
          socket.send(dataList, target, targetPort);
        } catch (_) {}
      }
    }
  }

  Future<List<String>> _localAddress() async {
    final addresses = <String>[];
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final netInterface in interfaces) {
      for (final netAddress in netInterface.addresses) {
        if (netAddress.address.isIPv4) {
          addresses.add(netAddress.address);
        }
      }
    }
    return addresses;
  }
}
