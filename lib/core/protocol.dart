/// 文件传输端口。
const int transferPort = 65001;

/// 连接控制端口（连接请求、断开）。
const int controlPort = 65002;

/// 文件加密分块大小。
const int fileChunkSize = 1024 * 1024;

/// 每个分块帧头长度（大端 4 字节密文长度）。
const int frameHeaderLength = 4;

/// 文件级随机前缀长度。
const int fileBaseNonceLength = 8;
