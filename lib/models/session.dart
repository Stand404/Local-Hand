import 'dart:typed_data';

/// 一次已建立的加密会话。
class HandSession {
  final String peerAddress;
  final String peerName;
  final String peerType;

  /// 由 ECDH 协商得到，仅存在于两端内存中的 AES-256 会话密钥。
  final Uint8List key;

  /// 本端是否为发起方。
  final bool initiator;

  const HandSession({
    required this.peerAddress,
    required this.peerName,
    required this.peerType,
    required this.key,
    required this.initiator,
  });

  String get peerTitle {
    if (peerName.isEmpty) return peerAddress;
    return '$peerName · $peerType';
  }
}
