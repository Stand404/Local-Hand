import 'package:flutter_test/flutter_test.dart';
import 'package:localhand/core/protocol.dart';

void main() {
  test('二维码配对信息可往返解析', () {
    const info = PairingInfo(
      ip: '192.168.1.8',
      port: 65002,
      code: 'ABCD2345',
      name: '小米手机',
      type: 'Android',
    );
    final parsed = PairingInfo.tryParse(info.encode());
    expect(parsed, isNotNull);
    expect(parsed!.ip, info.ip);
    expect(parsed.port, info.port);
    expect(parsed.code, info.code);
    expect(parsed.name, info.name);
    expect(parsed.type, info.type);
  });

  test('无效二维码返回 null', () {
    expect(PairingInfo.tryParse('hello'), isNull);
    expect(PairingInfo.tryParse('localhand://pair?d=AAAA'), isNull);
  });
}
