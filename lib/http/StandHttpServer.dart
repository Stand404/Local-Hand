// ignore_for_file: file_names
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:localhand/core/android_bridge.dart';
import 'package:localhand/core/crypto_worker.dart';
import 'package:localhand/core/file_storage.dart';
import 'package:localhand/core/protocol.dart';
import 'package:localhand/core/secure_channel.dart';

enum StandType { image, audio, document, video, program, other, text }

class StandFile {
  final String filename;
  final String filePath;
  final StandType fileType;
  final int size;

  StandFile(this.filename, this.filePath, this.fileType, {this.size = 0});
}

/// 接收端。消息使用会话密钥的 AES-256-GCM 解密，文件分块使用
/// AES-256-CTR + HMAC-SHA256 校验，失败的连接会被直接丢弃。
class StandHttpServer {
  final Uint8List key;
  final Function(StandFile standFile) receiveFileCallback;
  final Function(int index) receiveFileEndCallback;
  final Function(String message) receiveMsgCallback;
  final Function(double progress, int index) onProgress;
  final Function(int index, String error)? onReceiveError;

  HttpServer? _server;
  CryptoWorker? _worker;

  StandHttpServer({
    required this.key,
    required this.receiveFileCallback,
    required this.receiveFileEndCallback,
    required this.receiveMsgCallback,
    required this.onProgress,
    this.onReceiveError,
  }) {
    startServer();
  }

  Future<void> startServer() async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        transferPort,
        shared: true,
      );
      _server = server;
      server.listen(_handle);
    } on SocketException {
      // 端口被占用时等待下一个会话重新绑定。
    }
  }

  void closeServer() {
    _server?.close(force: true);
    _server = null;
    _worker?.close();
    _worker = null;
  }

  Future<CryptoWorker> _crypto() async =>
      _worker ??= await CryptoWorker.spawn(key);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/ping') {
        request.response.write('localhand');
        await request.response.close();
        return;
      }
      if (request.method != 'POST') {
        await _respond(request, HttpStatus.methodNotAllowed, {'ok': false});
        return;
      }

      switch (request.uri.path) {
        case '/msg':
          await _handleMessage(request);
          break;
        case '/file':
          await _handleFile(request);
          break;
        default:
          await _respond(request, HttpStatus.notFound, {'ok': false});
      }
    } catch (_) {
      try {
        await _respond(
            request, HttpStatus.badRequest, {'ok': false, 'reason': 'error'});
      } catch (_) {
        // 连接已断开。
      }
    }
  }

  Future<void> _handleMessage(HttpRequest request) async {
    final body = await _readAll(request, 2 * 1024 * 1024);
    String message;
    try {
      message = utf8.decode(
          openBytes(key, body, aad: utf8.encode('msg')));
    } catch (_) {
      await _respond(
          request, HttpStatus.badRequest, {'ok': false, 'reason': 'invalid'});
      return;
    }
    receiveMsgCallback(message);
    await _respond(request, HttpStatus.ok, {'ok': true});
  }

  Future<void> _handleFile(HttpRequest request) async {
    final nameBox = request.headers.value('x-lh-name');
    final sizeHeader = request.headers.value('x-lh-size');
    final chunksHeader = request.headers.value('x-lh-chunks');
    final nonceHeader = request.headers.value('x-lh-nonce');
    if (nameBox == null ||
        sizeHeader == null ||
        chunksHeader == null ||
        nonceHeader == null) {
      await _respond(
          request, HttpStatus.badRequest, {'ok': false, 'reason': 'headers'});
      return;
    }

    String filename;
    int totalSize;
    int totalChunks;
    Uint8List baseNonce;
    try {
      filename = utf8.decode(
          openBytes(key, base64Decode(nameBox), aad: utf8.encode('name')));
      totalSize = int.parse(sizeHeader);
      totalChunks = int.parse(chunksHeader);
      baseNonce = base64Decode(nonceHeader);
      if (totalSize < 0 || totalChunks < 1 ||
          baseNonce.length != fileBaseNonceLength) {
        throw const FormatException();
      }
      final expectedChunks =
          max(1, (totalSize + fileChunkSize - 1) ~/ fileChunkSize);
      if (totalChunks != expectedChunks) throw const FormatException();
    } catch (_) {
      await _respond(
          request, HttpStatus.badRequest, {'ok': false, 'reason': 'metadata'});
      return;
    }

    final directory = await receiveDirectory();
    final target = uniqueFile(directory, sanitizeFileName(filename));
    final partFile = File('${target.path}.part');
    final index = receiveFileCallback(StandFile(
      sanitizeFileName(filename),
      target.path,
      getFileType(filename),
      size: totalSize,
    ));

    final sink = partFile.openWrite();
    final reader = _BodyReader(request);
    final worker = await _crypto();
    var received = 0;
    var frames = 0;
    var sinkClosed = false;

    try {
      for (var i = 0; i < totalChunks; i++) {
        final header = await reader.readExact(frameHeaderLength);
        if (header == null) throw const FormatException('missing frame header');
        final length =
            ByteData.sublistView(header).getUint32(0, Endian.big);
        if (length < fileTagLength || length > fileChunkSize + fileTagLength) {
          throw const FormatException('invalid frame length');
        }
        final encrypted = await reader.readExact(length);
        if (encrypted == null) throw const FormatException('missing frame');
        final aad = utf8.encode('file|$i|$totalChunks|$nameBox');
        final plain = await worker.openChunk(baseNonce, i, encrypted, aad);
        sink.add(plain);
        received += plain.length;
        frames++;
        onProgress(
            totalSize == 0 ? 1 : min(1.0, received / totalSize), index);
      }

      await reader.close();
      await sink.flush();
      await sink.close();
      sinkClosed = true;

      if (frames != totalChunks || received != totalSize) {
        throw const FormatException('incomplete file');
      }
      if (await partFile.exists()) {
        await partFile.rename(target.path);
      }
    } catch (_) {
      if (!sinkClosed) {
        try {
          await sink.close();
        } catch (_) {}
      }
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
      onReceiveError?.call(index, '接收失败，数据校验未通过');
      await _respond(
          request, HttpStatus.badRequest, {'ok': false, 'reason': 'checksum'});
      return;
    }

    receiveFileEndCallback(index);
    unawaited(AndroidBridge.scanFile(target.path));
    await _respond(request, HttpStatus.ok, {'ok': true});
  }

  Future<List<int>> _readAll(HttpRequest request, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > maxBytes) throw const FormatException('body too large');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _respond(
      HttpRequest request, int statusCode, Map<String, dynamic> body) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}

/// 按帧读取 HTTP 请求体，避免把整个文件读入内存。
class _BodyReader {
  final StreamIterator<List<int>> _iterator;
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;
  bool _closed = false;

  _BodyReader(Stream<List<int>> stream) : _iterator = StreamIterator(stream);

  Future<bool> _ensure(int length) async {
    while (_buffer.length - _offset < length) {
      if (_closed || !await _iterator.moveNext()) {
        _closed = true;
        return false;
      }
      final chunk = _iterator.current;
      final remaining = _buffer.length - _offset;
      final merged = Uint8List(remaining + chunk.length);
      merged.setAll(0, _buffer.sublist(_offset));
      merged.setAll(remaining, chunk);
      _buffer = merged;
      _offset = 0;
    }
    return true;
  }

  Future<Uint8List?> readExact(int length) async {
    if (!await _ensure(length)) return null;
    final result =
        Uint8List.fromList(_buffer.sublist(_offset, _offset + length));
    _offset += length;
    if (_offset == _buffer.length) {
      _buffer = Uint8List(0);
      _offset = 0;
    }
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      // 直接 cancel 会让 dart:io 判定请求未读完并断开连接，
      // 客户端因此收不到 200 响应，出现“对方已收到但显示发送失败”。
      while (await _iterator.moveNext().timeout(const Duration(seconds: 5))) {
        // 丢弃请求体剩余字节。
      }
    } catch (_) {
      await _iterator.cancel();
    }
  }
}

// 根据文件扩展名判断文件类型
StandType getFileType(String filename) {
  final extension = filename.split('.').last.toLowerCase();
  switch (extension) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'bmp':
    case 'webp':
      return StandType.image;
    case 'mp3':
    case 'wav':
    case 'aac':
    case 'flac':
      return StandType.audio;
    case 'txt':
    case 'pdf':
    case 'doc':
    case 'docx':
    case 'xls':
    case 'xlsx':
    case 'ppt':
    case 'pptx':
      return StandType.document;
    case 'mp4':
    case 'avi':
    case 'mkv':
    case 'mov':
      return StandType.video;
    case 'exe':
    case 'dll':
    case 'so':
    case 'jar':
      return StandType.program;
    default:
      return StandType.other;
  }
}
