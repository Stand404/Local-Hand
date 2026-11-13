import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhand/core/crypto_worker.dart';
import 'package:localhand/core/protocol.dart';
import 'package:localhand/core/secure_channel.dart';

void main() {
  test('后台 isolate 加解密结果与主 isolate 一致', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i * 7));
    final worker = await CryptoWorker.spawn(key);

    final baseNonce = Uint8List.fromList(List.generate(fileBaseNonceLength, (i) => i));
    final plain = Uint8List.fromList(
        List.generate(256 * 1024, (i) => (i * 31) & 0xff));
    final aad = utf8.encode('file|0|1|test');

    final sealed = await worker.sealChunk(baseNonce, 0, plain, aad);
    final expected = sealChunk(key, baseNonce, 0, plain, aad);
    expect(sealed, expected);

    final opened = await worker.openChunk(baseNonce, 0, sealed, aad);
    expect(opened, plain);

    await expectLater(
      worker.openChunk(baseNonce, 0, Uint8List(sealed.length), aad),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      worker.openChunk(baseNonce, 1, sealed, aad),
      throwsA(isA<FormatException>()),
    );
    worker.close();
  });

  test('后台 isolate 池并行处理多个分块', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i * 13 + 1));
    final worker = await CryptoWorker.spawn(key);
    final baseNonce =
        Uint8List.fromList(List.generate(fileBaseNonceLength, (i) => i + 3));

    final plains = [
      for (var i = 0; i < 16; i++)
        Uint8List.fromList(
            List.generate(64 * 1024, (j) => (j + i * 17) & 0xff)),
    ];
    final aads = [for (var i = 0; i < plains.length; i++) utf8.encode('file|$i|16|bench')];

    final sealed = await Future.wait([
      for (var i = 0; i < plains.length; i++)
        worker.sealChunk(baseNonce, i, plains[i], aads[i]),
    ]);
    for (var i = 0; i < plains.length; i++) {
      expect(sealed[i], sealChunk(key, baseNonce, i, plains[i], aads[i]));
    }

    final opened = await Future.wait([
      for (var i = 0; i < sealed.length; i++)
        worker.openChunk(baseNonce, i, sealed[i], aads[i]),
    ]);
    for (var i = 0; i < plains.length; i++) {
      expect(opened[i], plains[i]);
    }
    worker.close();
  });
}
