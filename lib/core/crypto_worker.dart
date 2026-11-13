import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'secure_channel.dart';

/// 把文件分块的加密/校验计算放到常驻后台 isolate，避免大文件传输阻塞 UI。
///
/// 每个会话复用一个 isolate，分块请求按顺序执行；
/// 密钥只在创建时传给后台一次。
class CryptoWorker {
  CryptoWorker._(this._isolate, this._incoming, this._commands);

  final Isolate _isolate;
  final RawReceivePort _incoming;
  final SendPort _commands;
  final Map<int, Completer<Uint8List>> _pending = {};
  var _nextId = 0;
  bool _closed = false;

  static Future<CryptoWorker> spawn(Uint8List key) async {
    final incoming = RawReceivePort();
    final ready = Completer<SendPort>();
    late final CryptoWorker worker;

    incoming.handler = (message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      final list = message as List<Object?>;
      final id = list[0] as int;
      final completer = worker._pending.remove(id);
      if (completer == null) return;
      final error = list.length > 2 ? list[2] as String? : null;
      if (error != null) {
        completer.completeError(FormatException(error));
      } else {
        completer.complete(list[1] as Uint8List);
      }
    };

    final isolate = await Isolate.spawn(_workerMain, [incoming.sendPort, key]);
    final SendPort commands;
    try {
      commands = await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      incoming.close();
      rethrow;
    }
    worker = CryptoWorker._(isolate, incoming, commands);
    return worker;
  }

  Future<Uint8List> sealChunk(
      Uint8List baseNonce, int index, Uint8List plaintext, List<int> aad) {
    return _run(0, baseNonce, index, plaintext, aad);
  }

  Future<Uint8List> openChunk(
      Uint8List baseNonce, int index, Uint8List encrypted, List<int> aad) {
    return _run(1, baseNonce, index, encrypted, aad);
  }

  Future<Uint8List> _run(int mode, Uint8List baseNonce, int index,
      Uint8List data, List<int> aad) {
    if (_closed) {
      return Future.error(StateError('crypto worker closed'));
    }
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    _commands.send([id, mode, baseNonce, index, data, aad]);
    return completer.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _incoming.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('crypto worker closed'));
      }
    }
    _pending.clear();
  }
}

void _workerMain(List<Object?> args) {
  final mainPort = args[0] as SendPort;
  final key = args[1] as Uint8List;
  final commands = ReceivePort();
  mainPort.send(commands.sendPort);

  commands.listen((message) {
    final list = message as List<Object?>;
    final id = list[0] as int;
    final mode = list[1] as int;
    final baseNonce = list[2] as Uint8List;
    final index = list[3] as int;
    final data = list[4] as Uint8List;
    final aad = list[5] as List<int>;
    try {
      final result = mode == 0
          ? sealChunk(key, baseNonce, index, data, aad)
          : openChunk(key, baseNonce, index, data, aad);
      mainPort.send([id, result]);
    } catch (error) {
      final message = error is FormatException ? error.message : '$error';
      mainPort.send([id, null, message]);
    }
  });
}
