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
3. 端到端加密：ECDH P-256 协商会话密钥，AES-256-GCM 加密所有消息与文件
4. 扫码快速配对：展示二维码或扫描对方二维码，配对码一次有效，扫码后自动建立加密连接
5. 打开文件 (调出媒体播放器或选择其他方式弹窗)
6. 消息长按菜单 (复制文本、复制完整路径、打开文件位置)
7. 手机端接收文件后自动刷新媒体库，其他应用和文件管理器可立即看到；可一键打开接收目录

## 安全说明

- 每次连接都会生成临时 ECDH 密钥对，会话密钥只存在于内存中，退出连接即丢弃。
- 文件按 256 KB 分块加密传输，分块序号与文件信息参与认证，篡改、乱序或截断都会被拒绝。
- 文件名同样加密传输，接收端会过滤路径分隔符，避免恶意文件写到其他目录。
- 扫码配对使用一次性随机配对码；配对码不出现在二维码以外的位置，重新打开配对页会刷新。

## 权限说明

- Android：需要「所有文件访问权限」才能把接收的文件写入系统下载目录并刷新媒体库；需要相机权限用于扫码。
- iOS：需要相机（扫码）与本地网络（发现设备）权限。

## 安装

### Windows or Android
下载 [Releases](https://github.com/stand404/Local-Hand/releases) 的编译版本

目前只有 Android 和 Windows 应用程序，其他平台请自行构建，开发人员没有设备测试

## 许可证

该项目采用 MIT 许可证。

## 致谢

- [Flutter](https://docs.flutter.cn/) - 谷歌的移动UI框架.
