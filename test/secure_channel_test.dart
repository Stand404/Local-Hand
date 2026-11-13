import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhand/core/secure_channel.dart';

void main() {
  test('ECDH 双方派生出相同的会话密钥', () {
    final alice = generateKeyPair();
    final bob = generateKeyPair();
    final aliceKey = deriveSessionKey(
      privateKey: alice.privateKey,
      localPublicKey: alice.publicKey,
      peerPublicKey: bob.publicKey,
    );
    final bobKey = deriveSessionKey(
      privateKey: bob.privateKey,
      localPublicKey: bob.publicKey,
      peerPublicKey: alice.publicKey,
    );
    expect(aliceKey.length, 32);
    expect(aliceKey, bobKey);
  });

  test('AES-GCM 加解密往返', () {
    final key = randomBytes(32);
    final message = utf8.encode('你好，LocalHand');
    final sealed = sealBytes(key, message, aad: utf8.encode('msg'));
    expect(openBytes(key, sealed, aad: utf8.encode('msg')), message);
  });

  test('AAD 或密文被篡改时解密失败', () {
    final key = randomBytes(32);
    final sealed = sealBytes(key, utf8.encode('secret'), aad: utf8.encode('a'));

    expect(
      () => openBytes(key, sealed, aad: utf8.encode('b')),
      throwsFormatException,
    );

    final tampered = Uint8List.fromList(sealed);
    tampered[tampered.length - 1] ^= 0xff;
    expect(
      () => openBytes(key, tampered, aad: utf8.encode('a')),
      throwsFormatException,
    );
  });

  test('分块 IV 随序号变化且共享前缀', () {
    final base = randomBytes(8);
    final first = chunkIv(base, 1);
    final second = chunkIv(base, 2);
    expect(first.length, 16);
    expect(first.sublist(0, 8), base);
    expect(first, isNot(second));
    expect(chunkIv(Uint8List.fromList(base), 1), first);
  });

  test('分块加密往返，篡改或错位都会失败', () {
    final key = randomBytes(32);
    final base = randomBytes(8);
    final aad = utf8.encode('file|0|1|name');
    final plain = randomBytes(1000);

    final sealed = sealChunk(key, base, 0, plain, aad);
    expect(sealed.length, plain.length + fileTagLength);
    expect(openChunk(key, base, 0, sealed, aad), plain);

    final tampered = Uint8List.fromList(sealed);
    tampered[0] ^= 0xff;
    expect(() => openChunk(key, base, 0, tampered, aad), throwsFormatException);
    expect(() => openChunk(key, base, 1, sealed, aad), throwsFormatException);
    expect(
      () => openChunk(key, base, 0, sealed, utf8.encode('file|0|1|other')),
      throwsFormatException,
    );
  });

  test('文本加解密与错误密钥', () {
    final key = randomBytes(32);
    final encrypted = encryptText(key, 'hello');
    expect(decryptText(key, encrypted), 'hello');
    expect(() => decryptText(randomBytes(32), encrypted), throwsFormatException);
  });
}
