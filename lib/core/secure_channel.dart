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

/// 文件分块认证标签长度（HMAC-SHA256 截断）。
const int fileTagLength = 16;

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

/// 文件分块使用：8 字节随机前缀 + 4 字节大端分块序号 + 4 字节计数器。
Uint8List chunkIv(Uint8List baseNonce, int index) {
  final iv = Uint8List(16);
  iv.setAll(0, baseNonce);
  iv[8] = (index >> 24) & 0xff;
  iv[9] = (index >> 16) & 0xff;
  iv[10] = (index >> 8) & 0xff;
  iv[11] = index & 0xff;
  return iv;
}

Uint8List _deriveSubkey(Uint8List key, String label) {
  return Uint8List.fromList(crypto.sha256
      .convert(<int>[...utf8.encode('LocalHand/file/$label'), ...key])
      .bytes);
}

/// 文件分块加密：AES-256-CTR + HMAC-SHA256（先加密后认证）。
///
/// pointycastle 的 GCM 在纯 Dart 下只有约 1 MB/s，大文件会长时间占满 CPU；
/// CTR 与 HMAC 能到 50-90 MB/s，仍保持每块 16 字节认证开销。
Uint8List sealChunk(Uint8List key, Uint8List baseNonce, int index,
    List<int> plaintext, List<int> aad) {
  final input =
      plaintext is Uint8List ? plaintext : Uint8List.fromList(plaintext);
  final cipher = CTRStreamCipher(AESEngine())
    ..init(
        true,
        ParametersWithIV(
            KeyParameter(_deriveSubkey(key, 'enc')), chunkIv(baseNonce, index)));
  final ciphertext = cipher.process(input);
  final tag = _chunkTag(key, baseNonce, index, aad, ciphertext);
  final result = Uint8List(ciphertext.length + fileTagLength);
  result.setAll(0, ciphertext);
  result.setAll(ciphertext.length, tag);
  return result;
}

/// 校验认证标签后再解密；失败抛出 [FormatException]。
Uint8List openChunk(Uint8List key, Uint8List baseNonce, int index,
    List<int> data, List<int> aad) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  if (bytes.length < fileTagLength) {
    throw const FormatException('加密数据不完整');
  }
  final split = bytes.length - fileTagLength;
  final ciphertext = Uint8List.sublistView(bytes, 0, split);
  final tag = Uint8List.sublistView(bytes, split);
  if (!_constantTimeEquals(
      tag, _chunkTag(key, baseNonce, index, aad, ciphertext))) {
    throw const FormatException('数据校验失败');
  }
  final cipher = CTRStreamCipher(AESEngine())
    ..init(
        false,
        ParametersWithIV(
            KeyParameter(_deriveSubkey(key, 'enc')), chunkIv(baseNonce, index)));
  return cipher.process(ciphertext);
}

List<int> _chunkTag(Uint8List key, Uint8List baseNonce, int index,
    List<int> aad, List<int> ciphertext) {
  final sink = _DigestSink();
  final conversion =
      crypto.Hmac(crypto.sha256, _deriveSubkey(key, 'mac'))
          .startChunkedConversion(sink);
  conversion.add(aad);
  conversion.add(baseNonce);
  conversion.add(<int>[
    (index >> 24) & 0xff,
    (index >> 16) & 0xff,
    (index >> 8) & 0xff,
    index & 0xff,
  ]);
  conversion.add(ciphertext);
  conversion.close();
  return sink.value.bytes.sublist(0, fileTagLength);
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
