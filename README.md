中文 | [English](README_EN.md)

<div align="center">
    <img src="localhand_icon.png">
    <h1>Local Hand</h1>

[![image](https://img.shields.io/badge/bilibili-stand-orange.svg)](https://space.bilibili.com/382365750)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) 

一个基于flutter构建、简约、跨平台的局域网传输工具。

</div>

## 功能
1. 局域网自动发现设备，基于 TCP 控制通道建立连接，连接更可靠
2. 发送和接收文件、文字消息，支持一次选择多个文件
3. 端到端加密：ECDH P-256 协商会话密钥，消息使用 AES-256-GCM，文件分块使用 AES-256-CTR + HMAC-SHA256
4. 打开文件 (调出媒体播放器或选择其他方式弹窗)
5. 消息长按菜单 (复制文本、复制完整路径、打开文件位置)，桌面端支持右键菜单
6. 手机端接收文件后自动刷新媒体库，其他应用和文件管理器可立即看到；主界面与聊天页右上角均可一键打开接收目录
7. 桌面端体验：直接把文件拖入窗口即可发送 (支持多文件)，Enter 发送消息，宽屏窗口使用居中布局
8. 支持跟随系统、浅色、深色三种主题，选择会被记住

## 安全说明

- 每次连接都会生成临时 ECDH 密钥对，会话密钥只存在于内存中，退出连接即丢弃。
- 文件按 1 MB 分块加密传输，分块序号与文件信息参与认证，篡改、乱序或截断都会被拒绝；加解密在后台 isolate 池中多核并行，发送大文件时界面保持流畅。
- 文件名同样加密传输，接收端会过滤路径分隔符，避免恶意文件写到其他目录。

## 权限说明

- Android：需要「所有文件访问权限」才能把接收的文件写入系统下载目录并刷新媒体库。
- iOS：需要本地网络权限用于发现设备。

## 安装

### Windows or Android
下载 [Releases](https://github.com/stand404/Local-Hand/releases) 的编译版本

目前只有 Android 和 Windows 应用程序，其他平台请自行构建，开发人员没有设备测试

## 从源码构建

### 环境要求
- Flutter 3.41.9（Dart 3.11）
- Android：JDK 17、Android SDK（minSdk 24，compileSdk / targetSdk 36）
- Windows：Windows 10/11、Visual Studio 2026（勾选「使用 C++ 的桌面开发」工作负载）

### 构建命令
```bash
flutter pub get

# 调试运行
flutter run -d windows
flutter run -d <android-device-id>

# 发布构建
flutter build apk --release      # 产物：build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release  # 产物：build/windows/x64/runner/Release/
```

### 运行测试
```bash
flutter test
```

## 许可证

该项目采用 MIT 许可证。

## 致谢

- [Flutter](https://docs.flutter.cn/) - 谷歌的移动UI框架.
