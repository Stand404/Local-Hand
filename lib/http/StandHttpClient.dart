// ignore_for_file: file_names
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localhand/core/crypto_worker.dart';
import 'package:localhand/core/protocol.dart';
import 'package:localhand/core/secure_channel.dart';

import 'StandHttpServer.dart';

/// 发送端。文件按 256 KB 分块加密，边读边发，不会把大文件读进内存。
class StandHttpClient {
  final String address;
  final Uint8List key;
  final Function(String message, StandType type, String path, int size) onSent;
  final Function(double progress, int index) onProgress;
  final Function(int index, String error)? onSendError;

  CryptoWorker? _worker;

  StandHttpClient({
    required this.address,
    required this.key,
    required this.onSent,
    required this.onProgress,
    this.onSendError,
  });

  Future<CryptoWorker> _crypto() async =>
      _worker ??= await CryptoWorker.spawn(key);

  void dispose() {
    _worker?.close();
    _worker = null;
  }

  Future<bool> uploadFile(String filePath, String filename) async {
    final file = File(filePath);
    if (!await file.exists()) {
      final index = onSent(filename, getFileType(filename), filePath, 0);
      onSendError?.call(index, '文件不存在');
      return false;
    }

    final size = await file.length();
    final chunks = max(1, (size + fileChunkSize - 1) ~/ fileChunkSize);
    final baseNonce = randomBytes(fileBaseNonceLength);
    final nameBox = base64Encode(
        sealBytes(key, utf8.encode(filename), aad: utf8.encode('name')));
    final totalBody = size + chunks * (fileTagLength + frameHeaderLength);
    final index = onSent(filename, getFileType(filename), filePath, size);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 30);
    HttpClientRequest? request;
    RandomAccessFile? raf;

    try {
      final worker = await _crypto();
      request = await client
          .postUrl(Uri.parse('http://$address:$transferPort/file'))
          .timeout(const Duration(seconds: 10));
      request.headers.set('x-lh-name', nameBox);
      request.headers.set('x-lh-size', size.toString());
      request.headers.set('x-lh-chunks', chunks.toString());
      request.headers.set('x-lh-nonce', base64Encode(baseNonce));
      request.contentLength = totalBody;

      raf = await file.open();
      var sent = 0;
      for (var i = 0; i < chunks; i++) {
        final length = min(fileChunkSize, size - sent);
        final plain = await raf.read(length);
        final encrypted = await worker.sealChunk(
          baseNonce,
          i,
          plain,
          utf8.encode('file|$i|$chunks|$nameBox'),
        );
        final header = Uint8List(frameHeaderLength);
        ByteData.sublistView(header)
            .setUint32(0, encrypted.length, Endian.big);
        request.add(header);
        request.add(encrypted);
        await request.flush();
        sent += plain.length;
        onProgress(size == 0 ? 1 : min(1.0, sent / size), index);
      }

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      await response.drain<void>().timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('server returned ${response.statusCode}');
      }
      return true;
    } catch (_) {
      try {
        request?.abort();
      } catch (_) {}
      onSendError?.call(index, '发送失败，请检查连接');
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  Future<bool> sendMsg(String msg) async {
    final index = onSent(msg, StandType.text, '', 0);
    final box = sealBytes(key, utf8.encode(msg), aad: utf8.encode('msg'));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    HttpClientRequest? request;
    try {
      request = await client
          .postUrl(Uri.parse('http://$address:$transferPort/msg'))
          .timeout(const Duration(seconds: 10));
      request.contentLength = box.length;
      request.add(box);
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      await response.drain<void>().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('server returned ${response.statusCode}');
      }
      return true;
    } catch (_) {
      try {
        request?.abort();
      } catch (_) {}
      onSendError?.call(index, '消息发送失败');
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
