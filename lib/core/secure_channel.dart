import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// 本端临时密钥对。私钥只保留在内存中，连接结束后丢弃。
class LocalKeyPair {
  final ECPrivateKey privateKey;
  final String publicKey;

  const LocalKeyPair(this.privateKey, this.publicKey);
}

Uint8List randomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// 生成便于口述/输入的随机配对码，去掉了容易混淆的字符。
String randomPairingCode([int length = 8]) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(
      length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
}

/// 生成 P-256 临时密钥对。
LocalKeyPair generateKeyPair() {
  final curve = ECCurve_prime256v1();
  final d = _randomScalar(curve.n);
  final point = curve.G * d;
  if (point == null) {
    throw StateError('无法生成密钥对');
  }
  return LocalKeyPair(
    ECPrivateKey(d, curve),
    base64Encode(point.getEncoded(false)),
  );
}

BigInt _randomScalar(BigInt n) {
  var value = BigInt.zero;
  for (final byte in randomBytes(32)) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value % (n - BigInt.one) + BigInt.one;
}

/// 用 ECDH 共享秘密派生 32 字节会话密钥。
///
/// 密钥同时绑定双方公钥，避免不同连接被意外复用。
Uint8List deriveSessionKey({
  required ECPrivateKey privateKey,
  required String localPublicKey,
  required String peerPublicKey,
}) {
  final curve = ECCurve_prime256v1();
  ECPoint? point;
  try {
    point = curve.curve.decodePoint(base64Decode(peerPublicKey));
  } catch (_) {
    throw const FormatException('对方的公钥无效');
  }
  if (point == null || point.isInfinity) {
    throw const FormatException('对方的公钥无效');
  }

  final agreement = ECDHBasicAgreement()..init(privateKey);
  final shared = agreement.calculateAgreement(ECPublicKey(point, curve));
  final sharedBytes = _bigIntToBytes(shared, 32);
  final keys = <String>[localPublicKey, peerPublicKey]..sort();
  final transcript = utf8.encode('LocalHand/v1|${keys[0]}|${keys[1]}');
  return Uint8List.fromList(
      crypto.sha256.convert(<int>[...transcript, ...sharedBytes]).bytes);
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final result = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    result[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining = remaining >> 8;
  }
  return result;
}

const int gcmNonceLength = 12;
const int gcmTagLength = 16;
const int _gcmTagBits = 128;

/// AES-256-GCM 加密，返回 nonce + 密文 + tag。
Uint8List sealBytes(Uint8List key, List<int> plaintext,
    {List<int> aad = const []}) {
  final nonce = randomBytes(gcmNonceLength);
  final encrypted = sealWithNonce(key, nonce, plaintext, aad);
  final result = Uint8List(nonce.length + encrypted.length);
  result.setAll(0, nonce);
  result.setAll(nonce.length, encrypted);
  return result;
}

Uint8List sealWithNonce(
    Uint8List key, List<int> nonce, List<int> plaintext, List<int> aad) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
        true,
        AEADParameters(KeyParameter(key), _gcmTagBits,
            Uint8List.fromList(nonce), Uint8List.fromList(aad)));
  return cipher.process(Uint8List.fromList(plaintext));
}

/// 解密 nonce + 密文 + tag，校验失败会抛出 [FormatException]。
Uint8List openBytes(Uint8List key, List<int> data,
    {List<int> aad = const []}) {
  if (data.length < gcmNonceLength + gcmTagLength) {
    throw const FormatException('加密数据不完整');
  }
  final nonce = data.sublist(0, gcmNonceLength);
  final encrypted = data.sublist(gcmNonceLength);
  return openWithNonce(key, nonce, encrypted, aad);
}

Uint8List openWithNonce(
    Uint8List key, List<int> nonce, List<int> encrypted, List<int> aad) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
        false,
        AEADParameters(KeyParameter(key), _gcmTagBits,
            Uint8List.fromList(nonce), Uint8List.fromList(aad)));
  try {
    return cipher.process(Uint8List.fromList(encrypted));
  } on InvalidCipherTextException {
    throw const FormatException('数据校验失败');
  }
}

String encryptText(Uint8List key, String text, {String aad = 'msg'}) =>
    base64Encode(sealBytes(key, utf8.encode(text), aad: utf8.encode(aad)));

String decryptText(Uint8List key, String base64Data, {String aad = 'msg'}) =>
    utf8.decode(openBytes(key, base64Decode(base64Data), aad: utf8.encode(aad)));

/// 文件分块使用：8 字节随机前缀 + 4 字节大端分块序号。
Uint8List chunkNonce(Uint8List baseNonce, int index) {
  final nonce = Uint8List(gcmNonceLength);
  nonce.setAll(0, baseNonce);
  nonce[8] = (index >> 24) & 0xff;
  nonce[9] = (index >> 16) & 0xff;
  nonce[10] = (index >> 8) & 0xff;
  nonce[11] = index & 0xff;
  return nonce;
}
