import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/ConnectByOtherBottomSheet.dart';
import '../components/ConnectBySelfBottomSheet.dart';
import '../components/device_icon.dart';
import '../core/android_bridge.dart';
import '../core/file_storage.dart';
import '../core/theme_controller.dart';
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

  bool _storageGranted = true;
  bool _inSession = false;
  String? _activePeerAddress;
  String? _connectingAddress;
  int _connectToken = 0;
  bool _waitingSheetOpen = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

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
    }
  }

  Future<void> _checkStorage() async {
    if (!AndroidBridge.isAndroid) return;
    final ok = await canWriteReceiveDirectory();
    if (!mounted) return;
    setState(() => _storageGranted = ok);
  }

  Future<void> _requestStorage() async {
    await AndroidBridge.requestStorageAccess();
    // 系统设置或权限弹窗的返回时机不固定，轮询到接收目录真正可写为止。
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      if (await canWriteReceiveDirectory()) {
        setState(() => _storageGranted = true);
        return;
      }
    }
    if (!mounted) return;
    await _checkStorage();
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
    await _multicast.search();
  }

  Future<bool> _handleIncomingRequest(
      IncomingConnectionRequest request, HandSession session) async {
    if (_inSession || _connectingAddress != null) return false;

    if (!mounted) return false;
    context
        .read<Friends>()
        .addFriend(request.address, request.name, request.type);

    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 560),
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

  Future<void> _connectAddress(String address, {String? displayName}) async {
    if (_inSession || _connectingAddress != null) return;
    final target = address.trim();
    if (target.isEmpty) {
      _showSnack('请输入对方的 IP 地址');
      return;
    }

    final token = ++_connectToken;
    setState(() => _connectingAddress = target);

    final friend = context.read<Friends>().getFriendByAddress(target);
    final title = displayName ?? friend?.deviceName ?? (target);
    _showWaitingSheet(
        friend == null ? target : '$title · ${friend.deviceType} · $target');

    final outcome = await ControlClient.request(address: target);

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
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 560),
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

  Future<void> _openReceiveFolder() async {
    try {
      final dir = await receiveDirectory();
      if (!mounted) return;
      if (AndroidBridge.isAndroid) {
        final opened = await AndroidBridge.openFolder(dir.path);
        if (!opened && mounted) _showSnack('无法打开文件管理器');
      } else {
        final result = await OpenFile.open(dir.path);
        if (result.type != ResultType.done && mounted) {
          _showSnack('无法打开接收目录');
        }
      }
    } catch (_) {
      if (mounted) _showSnack('无法打开接收目录');
    }
  }

  Future<void> _openGitHub() async {
    const url = 'https://github.com/Stand404/Local-Hand';
    try {
      final opened =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened && mounted) _showSnack('无法打开浏览器，仓库地址：$url');
    } catch (_) {
      if (mounted) _showSnack('无法打开浏览器，仓库地址：$url');
    }
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
        body: RefreshIndicator(
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
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    final themeMode = context.watch<ThemeController>().mode;
    final themeIcon = switch (themeMode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };
    return SliverAppBar(
      pinned: true,
      toolbarHeight: 64,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: _centered(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'localhand_icon.png',
                  width: 38,
                  height: 38,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Local Hand',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '局域网文件与消息传输',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '打开接收目录',
                onPressed: _openReceiveFolder,
                icon: const Icon(Icons.folder_open_rounded, size: 22),
                color: colorScheme.onSurfaceVariant,
              ),
              PopupMenuButton<ThemeMode>(
                tooltip: '主题',
                position: PopupMenuPosition.under,
                color: colorScheme.surfaceContainerHigh,
                icon: Icon(themeIcon, size: 22),
                iconColor: colorScheme.onSurfaceVariant,
                onSelected: context.read<ThemeController>().setMode,
                itemBuilder: (context) => [
                  _themeMenuItem(ThemeMode.system, themeMode, colorScheme,
                      Icons.brightness_auto_rounded, '跟随系统'),
                  _themeMenuItem(ThemeMode.light, themeMode, colorScheme,
                      Icons.light_mode_rounded, '浅色'),
                  _themeMenuItem(ThemeMode.dark, themeMode, colorScheme,
                      Icons.dark_mode_rounded, '深色'),
                ],
              ),
              IconButton(
                tooltip: 'GitHub 仓库',
                onPressed: _openGitHub,
                icon: Image.asset(
                  'github_mark.png',
                  width: 21,
                  height: 21,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(
          height: 1,
          thickness: 1,
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
    );
  }

  Widget _buildStorageBanner(ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.55),
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

  PopupMenuItem<ThemeMode> _themeMenuItem(ThemeMode value, ThemeMode current,
      ColorScheme colorScheme, IconData icon, String label) {
    final selected = value == current;
    return PopupMenuItem<ThemeMode>(
      value: value,
      child: Row(
        children: [
          Icon(icon,
              size: 18,
              color: selected
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          if (selected)
            Icon(Icons.check_rounded, size: 18, color: colorScheme.primary),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ColorScheme colorScheme, int count) {
    return _centered(
      Padding(
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
      ),
    );
  }

  Widget _centered(Widget child) {
    if (!_isDesktop) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: child,
      ),
    );
  }

  Widget _buildDeviceCard(BuildContext context, Friend friend) {
    final colorScheme = Theme.of(context).colorScheme;
    final connecting = _connectingAddress == friend.address;
    final disabled = _inSession || _connectingAddress != null;

    return _centered(
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Material(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: disabled ? null : () => _connectDevice(friend),
            borderRadius: BorderRadius.circular(18),
            mouseCursor:
                disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
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
                    colorScheme.tertiaryContainer.withValues(alpha: 0.7),
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
              _isDesktop
                  ? '确认两台设备连接同一个局域网，\n然后下拉刷新或点击重新扫描'
                  : '确认两台设备连接同一个 Wi-Fi，\n然后下拉刷新或点击重新扫描',
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
