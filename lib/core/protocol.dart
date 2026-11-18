import 'dart:io';

/// 局域网发现默认端口（避开 Windows Hyper-V/WinNAT 保留的 49152-65535 动态端口段）。
const int discoveryPort = 26500;

/// 局域网发现候选端口列表；65000 仅作兼容旧版的最后回退。
const List<int> discoveryPorts = [26500, 26510, 65000];

/// 文件传输默认端口（避开 Windows Hyper-V/WinNAT 保留的 49152-65535 动态端口段）。
const int transferPort = 26501;

/// 连接控制默认端口（连接请求、断开；避开 49152-65535 动态端口段）。
const int controlPort = 26502;

/// 文件加密分块大小。
const int fileChunkSize = 1024 * 1024;

/// 每个分块帧头长度（大端 4 字节密文长度）。
const int frameHeaderLength = 4;

/// 文件级随机前缀长度。
const int fileBaseNonceLength = 8;

/// 解析有效 TCP/UDP 端口号。
int? parseValidPort(Object? value) {
  if (value is int && value > 0 && value <= 65535) return value;
  return null;
}

/// 优先绑定指定端口；若被占用或落在系统保留端口段，则回退到系统自动分配端口。
Future<HttpServer> bindServerPort(int preferredPort, {bool shared = true}) async {
  try {
    return await HttpServer.bind(
      InternetAddress.anyIPv4,
      preferredPort,
      shared: shared,
    );
  } on SocketException {
    return HttpServer.bind(
      InternetAddress.anyIPv4,
      0,
      shared: shared,
    );
  }
}
