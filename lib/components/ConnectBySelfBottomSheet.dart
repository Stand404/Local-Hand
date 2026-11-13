// ignore_for_file: file_names
import 'dart:math';

import 'package:flutter/material.dart';

/// 已发出连接请求，等待对方接受。
class CountdownBottomSheet extends StatefulWidget {
  final String peerTitle;
  final VoidCallback? onCancel;
  final int totalSeconds;

  const CountdownBottomSheet({
    super.key,
    required this.peerTitle,
    this.onCancel,
    this.totalSeconds = 65,
  });

  @override
  // ignore: library_private_types_in_public_api
  _CountdownBottomSheetState createState() => _CountdownBottomSheetState();
}

class _CountdownBottomSheetState extends State<CountdownBottomSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _countdown;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _countdown = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.totalSeconds),
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      })
      ..forward();
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _countdown.stop();
    widget.onCancel?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: 132,
                height: 132,
                child: AnimatedBuilder(
                  animation: _countdown,
                  builder: (context, _) {
                    final remaining = widget.totalSeconds == 0
                        ? 0
                        : (widget.totalSeconds * (1 - _countdown.value)).ceil();
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: const Size(132, 132),
                          painter: _WaitingRingPainter(
                            progress: widget.totalSeconds == 0
                                ? 0
                                : 1 - _countdown.value,
                            color: colorScheme.primary,
                            trackColor: colorScheme.outlineVariant
                                .withValues(alpha: 0.45),
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$remaining',
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.primary,
                              ),
                            ),
                            Text('秒',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              const Text('等待对方接受',
                  style:
                      TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                widget.peerTitle,
                style: TextStyle(
                    fontSize: 13, color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Text(
                '若对方长时间没有响应，请确认对方已打开 Local Hand',
                style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8)),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _finish,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: colorScheme.error,
                  side:
                      BorderSide(color: colorScheme.error.withValues(alpha: 0.35)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.close_rounded),
                label: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaitingRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color trackColor;

  _WaitingRingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, track);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      progress.clamp(0.0, 1.0) * 2 * pi,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _WaitingRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
