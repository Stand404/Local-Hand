import 'dart:io';
import 'dart:typed_data';

import 'package:localhand/core/protocol.dart';

/// 一次已建立的加密会话。
class HandSession {
  final String peerAddress;
  final String peerName;
  final String peerType;
  final int peerControlPort;
  final int peerTransferPort;
  final HttpServer? localTransferServer;

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
    this.peerControlPort = controlPort,
    this.peerTransferPort = transferPort,
    this.localTransferServer,
  });

  HandSession copyWith({
    int? peerControlPort,
    int? peerTransferPort,
    HttpServer? localTransferServer,
  }) {
    return HandSession(
      peerAddress: peerAddress,
      peerName: peerName,
      peerType: peerType,
      key: key,
      initiator: initiator,
      peerControlPort: peerControlPort ?? this.peerControlPort,
      peerTransferPort: peerTransferPort ?? this.peerTransferPort,
      localTransferServer: localTransferServer ?? this.localTransferServer,
    );
  }

  String get peerTitle {
    if (peerName.isEmpty) return peerAddress;
    return '$peerName · $peerType';
  }
}
