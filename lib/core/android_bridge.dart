import 'dart:io';

import 'package:flutter/services.dart';

/// 与 MainActivity 之间的原生通道：存储权限、媒体库刷新、打开文件夹。
class AndroidBridge {
  static const MethodChannel _channel =
      MethodChannel('com.stand.localhand/platform');

  static bool get isAndroid => Platform.isAndroid;

  static Future<bool> hasStorageAccess() async {
    if (!isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasStorageAccess') ?? false;
    } catch (_) {
      return true;
    }
  }

  /// 申请“所有文件访问权限”。Android 11+ 会跳转到系统设置页。
  static Future<bool> requestStorageAccess() async {
    if (!isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestStorageAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 通知 MediaStore 扫描新文件，否则刚接收的文件在其他应用/文件管理器里不可见。
  static Future<void> scanFile(String path, {String? mimeType}) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('scanFile', {
        'path': path,
        if (mimeType != null) 'mimeType': mimeType,
      });
    } catch (_) {
      // 扫描失败不影响文件本身。
    }
  }

  /// 用系统文件管理器打开接收目录。
  static Future<bool> openFolder(String path) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openFolder', {
            'path': path,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
