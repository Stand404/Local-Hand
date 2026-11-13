// ignore_for_file: file_names
import 'dart:math';

import 'package:flutter/material.dart';

import '../net/control_server.dart';
import 'device_icon.dart';

/// 收到对方的连接请求。
class ConnectByOtherBottomSheet extends StatefulWidget {
  final IncomingConnectionRequest request;
  final Function()? onAgree;
  final Function()? onRefuse;

  const ConnectByOtherBottomSheet({
    super.key,
    required this.request,
    this.onAgree,
    this.onRefuse,
  });

  @override
  // ignore: library_private_types_in_public_api
  _ConnectByOtherBottomSheet createState() => _ConnectByOtherBottomSheet();
}

class _ConnectByOtherBottomSheet extends State<ConnectByOtherBottomSheet>
    with SingleTickerProviderStateMixin {
  static const int _totalSeconds = 60;

  late final AnimationController _countdown;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _countdown = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _totalSeconds),
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish(widget.onRefuse);
      })
      ..forward();
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  void _finish(Function()? callback) {
    if (_finished) return;
    _finished = true;
    _countdown.stop();
    callback?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final request = widget.request;

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
              deviceAvatar(request.type, colorScheme, size: 64),
              const SizedBox(height: 14),
              Text(
                request.name,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                '${request.type} · ${request.address}',
                style: TextStyle(
                    fontSize: 13, color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded,
                      size: 15, color: colorScheme.primary),
                  const SizedBox(width: 5),
                  Text(
                    '请求建立端到端加密连接',
                    style: TextStyle(
                        fontSize: 13, color: colorScheme.primary),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 132,
                height: 132,
                child: AnimatedBuilder(
                  animation: _countdown,
                  builder: (context, _) {
                    final remaining =
                        (_totalSeconds * (1 - _countdown.value)).ceil();
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: const Size(132, 132),
                          painter: _CountdownRingPainter(
                            progress: 1 - _countdown.value,
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
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _finish(widget.onRefuse),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        foregroundColor: colorScheme.error,
                        side: BorderSide(
                            color: colorScheme.error.withValues(alpha: 0.35)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _finish(widget.onAgree),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('接受'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountdownRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color trackColor;

  _CountdownRingPainter({
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
  bool shouldRepaint(covariant _CountdownRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
