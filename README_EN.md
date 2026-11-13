English | [中文](README.md)

<div align="center">
    <img src="localhand_icon.png">
    <h1>Local Hand</h1>

[![image](https://img.shields.io/badge/bilibili-stand-orange.svg)](https://space.bilibili.com/382365750)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) 

A simple, cross-platform LAN transmission tool built on Flutter.

</div>

## Function

1. Automatic LAN discovery with a reliable TCP connection handshake
2. Send and receive files and text messages, with multi-file selection
3. End-to-end encryption: ECDH P-256 key agreement, AES-256-GCM for messages and AES-256-CTR + HMAC-SHA256 for file chunks
4. Open the file (bring up the media player or select another pop-up window)
5. Message long press menu (copy text, copy full path, open file location); right-click menu on desktop
6. Received files are scanned into the media library on Android, so other apps and file managers see them immediately; the receive folder opens in one tap from both the main screen and the chat screen
7. Desktop experience: drag files into the window to send them (multiple files supported), press Enter to send, centered layout on wide windows
8. Light, dark and system theme modes, with the choice remembered

## Security

- Every connection uses fresh ephemeral ECDH keys; session keys live only in memory and are discarded on disconnect.
- Files are streamed in encrypted 1 MB frames. Chunk order, chunk count and file metadata are authenticated, so tampering, reordering or truncation is rejected. Encryption runs in a pool of background isolates across CPU cores so large transfers keep the UI responsive.
- File names are encrypted too, and the receiver sanitizes them so peers cannot write outside the receive folder.

## Permissions

- Android: "All files access" is required to save received files into the system Downloads folder and refresh the media library.
- iOS: local network permission is required for device discovery.

## Installation

### Windows or Android
Download the compiled version of [Releases](https://github.com/stand114514/Local-Hand/releases)

Currently, only Android and Windows apps are available, please build your own for other platforms, and developers do not have device testing

## Building from source

### Requirements
- Flutter 3.41.9 (Dart 3.11)
- Android: JDK 17 and the Android SDK (minSdk 24, compileSdk / targetSdk 36)
- Windows: Windows 10/11 and Visual Studio 2026 with the "Desktop development with C++" workload

### Commands
```bash
flutter pub get

# Debug run
flutter run -d windows
flutter run -d <android-device-id>

# Release builds
flutter build apk --release      # output: build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release  # output: build/windows/x64/runner/Release/
```

### Run tests
```bash
flutter test
```

## License

This project is licensed under the MIT license.

## Thanks

- [Flutter](https://docs.flutter.cn/) - Google's mobile UI framework.