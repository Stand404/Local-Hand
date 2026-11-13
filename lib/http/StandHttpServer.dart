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
  final int port;
  final Function(StandFile standFile) receiveFileCallback;
  final Function(int index) receiveFileEndCallback;
  final Function(String message) receiveMsgCallback;
  final Function(double progress, int index) onProgress;
  final Function(int index, String error)? onReceiveError;

  HttpServer? _server;
  CryptoWorker? _worker;

  StandHttpServer({
    required this.key,
    this.port = transferPort,
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
        port,
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
      final window = worker.parallelism;

      Future<({int start, List<Uint8List> frames})> readBatch(
          int start) async {
        final batch = <Uint8List>[];
        var index = start;
        while (batch.length < window && index < totalChunks) {
          final header = await reader.readExact(frameHeaderLength);
          if (header == null) {
            throw const FormatException('missing frame header');
          }
          final length = ByteData.sublistView(header).getUint32(0, Endian.big);
          if (length < fileTagLength ||
              length > fileChunkSize + fileTagLength) {
            throw const FormatException('invalid frame length');
          }
          final encrypted = await reader.readExact(length);
          if (encrypted == null) throw const FormatException('missing frame');
          batch.add(encrypted);
          index++;
        }
        return (start: start, frames: batch);
      }

      // 下一批的接收提前启动，与当前批次的解密和写盘重叠。
      Future<({int start, List<Uint8List> frames})> prefetch(int start) {
        final completer = Completer<({int start, List<Uint8List> frames})>();
        readBatch(start)
            .then(completer.complete, onError: completer.completeError);
        return completer.future;
      }

      var next = window;
      Future<({int start, List<Uint8List> frames})>? pending = prefetch(0);
      try {
        while (pending != null) {
          final batch = await pending;
          pending = next < totalChunks ? prefetch(next) : null;
          next += window;
          final plains = await Future.wait([
            for (var k = 0; k < batch.frames.length; k++)
              worker.openChunk(
                baseNonce,
                batch.start + k,
                batch.frames[k],
                utf8.encode('file|${batch.start + k}|$totalChunks|$nameBox'),
              ),
          ]);
          for (final plain in plains) {
            sink.add(plain);
            received += plain.length;
          }
          frames += plains.length;
          final flushing = sink.flush();
          onProgress(
              totalSize == 0 ? 1 : min(1.0, received / totalSize), index);
          await flushing;
        }
      } finally {
        pending?.ignore();
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
  final List<List<int>> _chunks = [];
  int _buffered = 0;
  bool _closed = false;

  _BodyReader(Stream<List<int>> stream) : _iterator = StreamIterator(stream);

  Future<bool> _ensure(int length) async {
    while (_buffered < length) {
      if (_closed || !await _iterator.moveNext()) {
        _closed = true;
        return false;
      }
      final chunk = _iterator.current;
      if (chunk.isEmpty) continue;
      _chunks.add(chunk);
      _buffered += chunk.length;
    }
    return true;
  }

  Future<Uint8List?> readExact(int length) async {
    if (!await _ensure(length)) return null;
    final result = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      final chunk = _chunks.first;
      final take = min(length - filled, chunk.length);
      result.setRange(filled, filled + take, chunk);
      filled += take;
      _buffered -= take;
      if (take == chunk.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = chunk.sublist(take);
      }
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
