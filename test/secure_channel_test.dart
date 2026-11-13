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

  test('分块 nonce 随序号变化且共享前缀', () {
    final base = randomBytes(8);
    final first = chunkNonce(base, 1);
    final second = chunkNonce(base, 2);
    expect(first.sublist(0, 8), base);
    expect(first, isNot(second));
    expect(chunkNonce(Uint8List.fromList(base), 1), first);
  });

  test('文本加解密与错误密钥', () {
    final key = randomBytes(32);
    final encrypted = encryptText(key, 'hello');
    expect(decryptText(key, encrypted), 'hello');
    expect(() => decryptText(randomBytes(32), encrypted), throwsFormatException);
  });
}
