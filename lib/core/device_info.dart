import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

class LocalDevice {
  final String name;
  final String type;

  const LocalDevice(this.name, this.type);

  String get displayName => name.isEmpty ? type : name;
}

Future<LocalDevice>? _localDeviceFuture;

/// 本机名称与平台类型，结果会被缓存。
Future<LocalDevice> loadLocalDevice() {
  return _localDeviceFuture ??= _readLocalDevice();
}

Future<LocalDevice> _readLocalDevice() async {
  final deviceInfo = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      return LocalDevice(_capitalize(info.manufacturer), 'Android');
    }
    if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      return LocalDevice(info.name, 'iOS');
    }
    if (Platform.isWindows) {
      final info = await deviceInfo.windowsInfo;
      return LocalDevice(info.computerName, 'Windows');
    }
    if (Platform.isLinux) {
      final info = await deviceInfo.linuxInfo;
      return LocalDevice(info.name, 'Linux');
    }
    if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      return LocalDevice(info.computerName, 'MacOS');
    }
  } catch (_) {
    // 某些平台信息不可用时保持通用名称。
  }
  return const LocalDevice('未知设备', '未知');
}

String _capitalize(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}
