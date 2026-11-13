import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../components/ConnectByOtherBottomSheet.dart';
import '../components/ConnectBySelfBottomSheet.dart';
import '../components/qr_pair_sheet.dart';
import '../components/device_icon.dart';
import '../core/android_bridge.dart';
import '../core/device_info.dart';
import '../core/protocol.dart';
import '../core/secure_channel.dart';
import '../models/friends.dart';
import '../models/session.dart';
import '../multicast.dart';
import '../net/control_client.dart';
import '../net/control_server.dart';
import 'hand_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late Multicast _multicast;
  late ControlServer _controlServer;
  final ValueNotifier<bool> _isClose = ValueNotifier(false);

  String _myHost = '';
  LocalDevice _device = const LocalDevice('未知设备', '未知');
  bool _storageGranted = true;

  bool _inSession = false;
  String? _activePeerAddress;
  String? _connectingAddress;
  int _connectToken = 0;
  bool _waitingSheetOpen = false;

  PairingInfo? _pairingInfo;
  bool _qrSheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _multicast = Multicast(friendCallback: _onDiscovery);
    _controlServer = ControlServer(
      onRequest: _handleIncomingRequest,
      onSessionReady: _enterSession,
      onPeerClosed: (address) {
        if (_inSession && address == _activePeerAddress) {
          _isClose.value = true;
        }
      },
    );
    _controlServer.start();

    _refreshLocalInfo();
    _checkStorage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _multicast.search();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlServer.close();
    _isClose.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStorage();
      _refreshLocalInfo();
    }
  }

  Future<void> _refreshLocalInfo() async {
    final host = await _multicast.loadLocalHost();
    final device = await loadLocalDevice();
    if (!mounted) return;
    setState(() {
      _myHost = host;
      _device = device;
    });
  }

  Future<void> _checkStorage() async {
    if (!AndroidBridge.isAndroid) return;
    final granted = await AndroidBridge.hasStorageAccess();
    if (!mounted) return;
    setState(() => _storageGranted = granted);
  }

  Future<void> _requestStorage() async {
    await AndroidBridge.requestStorageAccess();
    await Future.delayed(const Duration(milliseconds: 400));
    await _checkStorage();
    if (!mounted) return;
    if (!_storageGranted) {
      _showSnack('请在系统设置中允许 Local Hand 访问所有文件');
    }
  }

  void _onDiscovery(FriendMsgType type, String message) {
    if (!mounted) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      final address = decoded['address'];
      final name = decoded['deviceName'];
      final deviceType = decoded['deviceType'];
      if (address is String && name is String && deviceType is String) {
        context.read<Friends>().addFriend(address, name, deviceType);
      }
    } catch (_) {
      // 忽略格式不正确的发现消息。
    }
  }

  Future<void> _refreshDevices() async {
    if (!mounted) return;
    context.read<Friends>().removeStale();
    await _refreshLocalInfo();
    await _multicast.search();
  }

  Future<bool> _handleIncomingRequest(
      IncomingConnectionRequest request, HandSession session) async {
    if (_inSession || _connectingAddress != null) return false;

    // 扫码配对：配对码匹配时直接接受，不再弹窗。
    final pairing = _pairingInfo;
    if (pairing != null &&
        request.pairingCode != null &&
        request.pairingCode == pairing.code) {
      _closeQrSheet();
      await Future.delayed(const Duration(milliseconds: 220));
      return true;
    }

    if (!mounted) return false;
    if (mounted) {
      context
          .read<Friends>()
          .addFriend(request.address, request.name, request.type);
    }

    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ConnectByOtherBottomSheet(
        request: request,
        onRefuse: () => Navigator.of(sheetContext).pop(false),
        onAgree: () => Navigator.of(sheetContext).pop(true),
      ),
    );
    return accepted ?? false;
  }

  void _enterSession(HandSession session) {
    if (!mounted) return;
    if (_inSession) {
      unawaited(ControlClient.close(session.peerAddress));
      return;
    }
    _closeQrSheet();
    _inSession = true;
    _activePeerAddress = session.peerAddress;
    _isClose.value = false;

    Navigator.of(context)
        .push(CupertinoPageRoute(
          builder: (_) => HandPage(session: session, isClose: _isClose),
        ))
        .then((_) {
      if (!mounted) return;
      _inSession = false;
      _activePeerAddress = null;
      _isClose.value = false;
      _refreshDevices();
    });
  }

  Future<void> _connectDevice(Friend friend) {
    return _connectAddress(friend.address, displayName: friend.deviceName);
  }

  Future<void> _connectAddress(String address,
      {String? pairingCode, String? displayName}) async {
    if (_inSession || _connectingAddress != null) return;
    final target = address.trim();
    if (target.isEmpty) {
      _showSnack('请输入对方的 IP 地址');
      return;
    }

    final token = ++_connectToken;
    setState(() => _connectingAddress = target);

    final friend = context.read<Friends>().getFriendByAddress(target);
    final title = displayName ??
        friend?.deviceName ??
        (target);
    _showWaitingSheet(
        friend == null ? target : '$title · ${friend.deviceType} · $target');

    final outcome = await ControlClient.request(
      address: target,
      pairingCode: pairingCode,
    );

    if (!mounted) return;
    if (token != _connectToken) {
      // 用户已取消等待；若对方随后接受了请求，顺手通知对方断开。
      if (outcome.ok) unawaited(ControlClient.close(target));
      return;
    }

    _closeWaitingSheet();
    setState(() => _connectingAddress = null);

    if (outcome.ok) {
      _enterSession(outcome.session!);
    } else {
      _showSnack(outcome.error);
    }
  }

  void _showWaitingSheet(String peerTitle) {
    _waitingSheetOpen = true;
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => CountdownBottomSheet(
        peerTitle: peerTitle,
        onCancel: _cancelConnect,
      ),
    ).whenComplete(() => _waitingSheetOpen = false);
  }

  void _closeWaitingSheet() {
    if (!_waitingSheetOpen) return;
    _waitingSheetOpen = false;
    if (mounted) Navigator.of(context).pop();
  }

  void _cancelConnect() {
    _connectToken++;
    _closeWaitingSheet();
    if (!mounted) return;
    setState(() => _connectingAddress = null);
  }

  Future<void> _openPairSheet() async {
    if (_connectingAddress != null || _inSession) return;
    if (_myHost.isEmpty) {
      _showSnack('未获取到本机局域网 IP，请先连接 Wi-Fi 或网线');
      return;
    }
    final device = await loadLocalDevice();
    if (!mounted) return;
    final info = PairingInfo(
      ip: _myHost,
      port: controlPort,
      code: randomPairingCode(),
      name: device.name,
      type: device.type,
    );
    setState(() {
      _pairingInfo = info;
      _qrSheetOpen = true;
    });

    final action = await showModalBottomSheet<PairAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QrPairSheet(
        info: info,
        canScan: Platform.isAndroid || Platform.isIOS,
      ),
    );

    _qrSheetOpen = false;
    if (!mounted) return;
    setState(() => _pairingInfo = null);
    if (action != null) {
      await _connectAddress(action.ip, pairingCode: action.code);
    }
  }

  void _closeQrSheet() {
    if (!_qrSheetOpen) return;
    _qrSheetOpen = false;
    if (mounted) Navigator.of(context).pop();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Consumer<Friends>(builder: (context, friends, _) {
      final devices = friends.friends;
      return Scaffold(
        backgroundColor: colorScheme.surface,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _openPairSheet,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: const Text('扫码配对'),
        ),
        body: RefreshIndicator(
          edgeOffset: 140,
          onRefresh: _refreshDevices,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _buildHeader(colorScheme),
              if (AndroidBridge.isAndroid && !_storageGranted)
                SliverToBoxAdapter(child: _buildStorageBanner(colorScheme)),
              SliverToBoxAdapter(
                  child: _buildSectionHeader(colorScheme, devices.length)),
              if (devices.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(colorScheme),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _buildDeviceCard(context, devices[index]),
                    childCount: devices.length,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    return SliverAppBar(
      pinned: true,
      expandedHeight: 208,
      toolbarHeight: 64,
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      titleSpacing: 20,
      title: const Text(
        'Local Hand',
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22),
      ),
      actions: [
        IconButton(
          tooltip: '刷新设备',
          onPressed: _refreshDevices,
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: '扫码配对',
          onPressed: _openPairSheet,
          icon: const Icon(Icons.qr_code_2_rounded),
        ),
        const SizedBox(width: 6),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.primary,
                Color.lerp(colorScheme.primary, colorScheme.tertiary, 0.55)!,
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -40,
                top: 10,
                child: _decorCircle(160, Colors.white.withOpacity(0.06)),
              ),
              Positioned(
                right: 60,
                bottom: 10,
                child: _decorCircle(90, Colors.white.withOpacity(0.05)),
              ),
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 76, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '局域网文件与消息传输',
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onPrimary.withOpacity(0.82),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          _headerChip(
                            Icons.wifi_rounded,
                            _myHost.isEmpty ? '未连接网络' : '本机 $_myHost',
                          ),
                          const SizedBox(width: 8),
                          _headerChip(
                            deviceIconData(_device.type),
                            _device.displayName,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _decorCircle(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _headerChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageBanner(ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withOpacity(0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_shared_rounded, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('需要文件访问权限',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  '授权后才能保存接收的文件到下载目录',
                  style: TextStyle(
                      fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _requestStorage,
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ColorScheme colorScheme, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 6),
      child: Row(
        children: [
          Text(
            '附近设备',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _refreshDevices,
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(BuildContext context, Friend friend) {
    final colorScheme = Theme.of(context).colorScheme;
    final connecting = _connectingAddress == friend.address;
    final disabled = _inSession || _connectingAddress != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Material(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: disabled ? null : () => _connectDevice(friend),
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                deviceAvatar(friend.deviceType, colorScheme),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        friend.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${friend.deviceType} · ${friend.address}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (connecting)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                else
                  FilledButton.tonal(
                    onPressed: disabled ? null : () => _connectDevice(friend),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('连接'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 120),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colorScheme.primaryContainer,
                    colorScheme.tertiaryContainer.withOpacity(0.7),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.devices_rounded,
                  size: 44, color: colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 22),
            const Text(
              '还没有发现设备',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '确认两台设备连接同一个 Wi-Fi，\n然后下拉刷新，或直接使用扫码配对',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _refreshDevices,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新扫描'),
            ),
          ],
        ),
      ),
    );
  }
}
