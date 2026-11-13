import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/protocol.dart';

/// 扫码/手输 IP 后返回的连接动作。
class PairAction {
  final String ip;
  final String? code;

  const PairAction(this.ip, {this.code});
}

class QrPairSheet extends StatelessWidget {
  final PairingInfo info;
  final bool canScan;

  const QrPairSheet({super.key, required this.info, required this.canScan});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: canScan ? 2 : 1,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.82,
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Icon(Icons.qr_code_2_rounded, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    const Text('扫码配对',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              if (canScan)
                TabBar(
                  tabs: const [
                    Tab(text: '我的二维码'),
                    Tab(text: '扫一扫'),
                  ],
                  labelColor: colorScheme.primary,
                  indicatorColor: colorScheme.primary,
                ),
              Expanded(
                child: canScan
                    ? TabBarView(
                        children: [
                          _MyQrTab(info: info),
                          const _ScanTab(),
                        ],
                      )
                    : _MyQrTab(info: info),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MyQrTab extends StatefulWidget {
  final PairingInfo info;

  const _MyQrTab({required this.info});

  @override
  State<_MyQrTab> createState() => _MyQrTabState();
}

class _MyQrTabState extends State<_MyQrTab> {
  final TextEditingController _ipController = TextEditingController();

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final info = widget.info;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
      child: Column(
        children: [
          Text(
            '用另一台设备上的 Local Hand 扫描二维码',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: QrImageView(
              data: info.encode(),
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
              padding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '配对码 ${info.code}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 18,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'IP ${info.ip} · 扫码后自动建立加密连接，无需对方确认',
            style:
                TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('无法扫码？手动连接',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '对方 IP，例如 192.168.1.8',
                    isDense: true,
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest
                        .withOpacity(0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () {
                  final ip = _ipController.text.trim();
                  if (ip.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请先输入对方 IP')));
                    return;
                  }
                  Navigator.pop(context, PairAction(ip));
                },
                child: const Text('连接'),
              ),
            ],
          ),
          if (Platform.isAndroid || Platform.isIOS)
            const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ScanTab extends StatefulWidget {
  const _ScanTab();

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  final MobileScannerController _controller = MobileScannerController(
    autoStart: true,
    facing: CameraFacing.back,
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final info = PairingInfo.tryParse(raw);
      if (info == null) continue;
      _handled = true;
      HapticFeedback.mediumImpact();
      Navigator.pop(context, PairAction(info.ip, code: info.code));
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (context, error, child) {
                      return Container(
                        color: Colors.black87,
                        padding: const EdgeInsets.all(24),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.no_photography_rounded,
                                color: Colors.white70, size: 48),
                            SizedBox(height: 12),
                            Text('无法打开相机，请检查相机权限',
                                style: TextStyle(color: Colors.white70),
                                textAlign: TextAlign.center),
                          ],
                        ),
                      );
                    },
                  ),
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: colorScheme.primary.withOpacity(0.9),
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      margin: const EdgeInsets.all(48),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '将对方设备上的二维码放入取景框',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
