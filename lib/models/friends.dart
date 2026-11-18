import 'package:flutter/cupertino.dart';
import 'package:localhand/core/protocol.dart';

class Friend {
  String address;
  String deviceName;
  String deviceType;
  int port;
  DateTime lastSeen;

  Friend(this.address, this.deviceName, this.deviceType,
      {this.port = controlPort, DateTime? lastSeen})
      : lastSeen = lastSeen ?? DateTime.now();
}

class Friends extends ChangeNotifier {
  final Map<String, Friend> friendsMap = {};

  List<Friend> get friends {
    final list = friendsMap.values.toList();
    list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  void addFriend(String address, String deviceName, String deviceType,
      {int port = controlPort}) {
    final existing = friendsMap[address];
    if (existing == null) {
      friendsMap[address] = Friend(address, deviceName, deviceType,
          port: port, lastSeen: DateTime.now());
      notifyListeners();
      return;
    }
    final changed = existing.deviceName != deviceName ||
        existing.deviceType != deviceType ||
        existing.port != port;
    existing.deviceName = deviceName;
    existing.deviceType = deviceType;
    existing.port = port;
    existing.lastSeen = DateTime.now();
    if (changed) notifyListeners();
  }

  /// 刷新设备列表前清理长时间未响应的设备。
  void removeStale({Duration maxAge = const Duration(seconds: 20)}) {
    final now = DateTime.now();
    final stale = friendsMap.entries
        .where((entry) => now.difference(entry.value.lastSeen) > maxAge)
        .map((entry) => entry.key)
        .toList();
    if (stale.isEmpty) return;
    for (final address in stale) {
      friendsMap.remove(address);
    }
    notifyListeners();
  }

  Friend? getFriendByAddress(String address) => friendsMap[address];
}

enum FriendMsgType {
  // ignore: constant_identifier_names
  message,
}
