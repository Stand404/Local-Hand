import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localhand/components/ConnectBySelfBottomSheet.dart';
import 'package:localhand/components/MessageWidget.dart';
import 'package:localhand/http/StandHttpServer.dart';

void main() {
  testWidgets('倒计时环形进度连续推进，不是每秒跳一格', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CountdownBottomSheet(peerTitle: 'peer', totalSeconds: 65),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    double ringProgress() {
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .firstWhere((painter) => painter.runtimeType.toString().contains('Ring'));
      return (painter as dynamic).progress as double;
    }

    final before = ringProgress();
    await tester.pump(const Duration(milliseconds: 500));
    final after = ringProgress();

    expect(after, lessThan(before));
    // 半秒内推进约 0.5/65，说明进度在帧级别连续变化。
    expect(before - after, closeTo(0.5 / 65, 0.02));
  });

  testWidgets('传输进度变化时进度条平滑补间', (tester) async {
    Widget build(double value) => MaterialApp(
          home: Scaffold(
            body: MessageWidget(
              message: 'setup.exe',
              path: '',
              type: StandType.program,
              progress: value,
              size: 1024 * 1024,
              mine: true,
            ),
          ),
        );

    await tester.pumpWidget(build(0.2));
    await tester.pumpWidget(build(0.8));
    await tester.pump(const Duration(milliseconds: 100));

    double barValue() => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;

    expect(barValue(), greaterThan(0.2));
    expect(barValue(), lessThan(0.8));

    await tester.pump(const Duration(milliseconds: 300));
    expect(barValue(), closeTo(0.8, 0.001));
  });
}
