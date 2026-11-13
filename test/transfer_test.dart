import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localhand/core/secure_channel.dart';
import 'package:localhand/http/StandHttpClient.dart';
import 'package:localhand/http/StandHttpServer.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

Future<void> _waitForServer(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/ping'));
      final response = await request.close();
      await response.drain<void>();
      final ok = response.statusCode == HttpStatus.ok;
      client.close(force: true);
      if (ok) return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  throw StateError('服务端未在预期时间内启动');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 测试绑定默认会把所有 HttpClient 请求拦成 400，这里恢复真实网络。
    HttpOverrides.global = null;
  });

  test('文件通过真实 HTTP 连接加密传输，内容一致', () async {
    final root = await Directory.systemTemp.createTemp('lh_transfer_');
    final sourceDir = Directory('${root.path}${Platform.pathSeparator}src');
    final receiveDir = Directory('${root.path}${Platform.pathSeparator}recv');
    await sourceDir.create();
    await receiveDir.create();
    PathProviderPlatform.instance = _FakePathProvider(receiveDir.path);

    final key = randomBytes(32);
    // 避免与本机正在运行的应用争用固定端口。
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final source = File('${sourceDir.path}${Platform.pathSeparator}sample.bin');
    final random = Random(42);
    final payload = Uint8List.fromList(
        List.generate(1024 * 1024, (_) => random.nextInt(256)));
    await source.writeAsBytes(payload);

    var finished = false;
    final server = StandHttpServer(
      key: key,
      port: port,
      receiveFileCallback: (_) => 0,
      receiveFileEndCallback: (_) => finished = true,
      receiveMsgCallback: (_) {},
      onProgress: (_, __) {},
      onReceiveError: (_, error) => fail('接收失败: $error'),
    );
    final client = StandHttpClient(
      address: '127.0.0.1',
      port: port,
      key: key,
      onSent: (message, type, path, size) => 0,
      onProgress: (_, __) {},
      onSendError: (_, error) => fail('发送失败: $error'),
    );

    try {
      await _waitForServer(port);
      final ok = await client.uploadFile(source.path, 'sample.bin');
      expect(ok, isTrue);
      expect(finished, isTrue);

      final saved = File('${receiveDir.path}${Platform.pathSeparator}sample.bin');
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsBytes(), payload);
    } finally {
      client.dispose();
      server.closeServer();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
