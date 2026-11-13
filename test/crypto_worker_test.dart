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
}
