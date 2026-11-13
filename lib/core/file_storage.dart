import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 接收文件目录：Android 放在系统下载目录下，方便其他应用查找；
/// 桌面端沿用系统下载目录。
Future<Directory> receiveDirectory() async {
  if (Platform.isAndroid) {
    final dir = Directory('/storage/emulated/0/Download/LocalHand');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
  final downloads = await getDownloadsDirectory();
  final dir = downloads ?? Directory.current;
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 去掉路径分隔符和非法字符，避免对方构造恶意文件名写到其他目录。
String sanitizeFileName(String name) {
  var base = name.replaceAll('\\', '/').split('/').last.trim();
  base = base.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
  if (base.isEmpty || base == '.' || base == '..') {
    base = 'received_${DateTime.now().millisecondsSinceEpoch}';
  }

  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  final extension = dot > 0 ? base.substring(dot) : '';
  const reserved = {
    'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5',
    'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5',
    'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  var safeStem = stem;
  if (reserved.contains(stem.toUpperCase())) {
    safeStem = '_$stem';
  }
  if (safeStem.length > 120) {
    safeStem = safeStem.substring(0, 120);
  }
  return '$safeStem$extension';
}

/// 同名文件自动追加序号。
File uniqueFile(Directory directory, String fileName) {
  final separator = Platform.pathSeparator;
  var candidate = File('${directory.path}$separator$fileName');
  if (!candidate.existsSync()) return candidate;

  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final extension = dot > 0 ? fileName.substring(dot) : '';
  for (var i = 1; i < 1000; i++) {
    candidate = File('${directory.path}$separator$stem ($i)$extension');
    if (!candidate.existsSync()) return candidate;
  }
  return File('${directory.path}$separator${DateTime.now().millisecondsSinceEpoch}_$fileName');
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
