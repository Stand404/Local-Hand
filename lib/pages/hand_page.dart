import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';

import '../components/MessageWidget.dart';
import '../components/device_icon.dart';
import '../core/android_bridge.dart';
import '../core/file_storage.dart';
import '../http/StandHttpClient.dart';
import '../http/StandHttpServer.dart';
import '../models/session.dart';
import '../net/control_client.dart';

enum MessageCenter { left, right }

class StandMessage {
  final String time;
  final String message;
  final String path;
  final StandType type;
  final MessageCenter center;
  final int size;
  double progress;
  bool failed;
  String? error;

  StandMessage(
    this.time,
    this.message,
    this.path,
    this.type,
    this.center,
    this.progress, {
    this.size = 0,
    this.failed = false,
    this.error,
  });
}

class HandPage extends StatefulWidget {
  final ValueNotifier<bool> isClose;
  final HandSession session;

  const HandPage({
    super.key,
    required this.isClose,
    required this.session,
  });

  @override
  State<HandPage> createState() => _HandPageState();
}

class _HandPageState extends State<HandPage> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  final List<StandMessage> _messages = [];

  late StandHttpServer _standHttpServer;
  late StandHttpClient _standHttpClient;

  bool _peerClosed = false;
  bool _sendingFiles = false;
  bool _allowPop = false;
  bool _dragging = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _peerClosed = widget.isClose.value;
    widget.isClose.addListener(_onPeerStateChanged);

    _standHttpServer = StandHttpServer(
      key: widget.session.key,
      receiveFileCallback: _receiveFile,
      receiveFileEndCallback: _receiveFileEnd,
      receiveMsgCallback: _receiveMsg,
      onProgress: _updateProgress,
      onReceiveError: _markFailed,
    );
    _standHttpClient = StandHttpClient(
      address: widget.session.peerAddress,
      key: widget.session.key,
      onSent: _onSent,
      onProgress: _updateProgress,
      onSendError: _markFailed,
    );
  }

  @override
  void dispose() {
    widget.isClose.removeListener(_onPeerStateChanged);
    _standHttpServer.closeServer();
    unawaited(ControlClient.close(widget.session.peerAddress));
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _onPeerStateChanged() {
    if (!mounted) return;
    setState(() => _peerClosed = widget.isClose.value);
  }

  String get _timeText => DateFormat('MM-dd HH:mm').format(DateTime.now());

  int _onSent(String message, StandType type, String path, int size) {
    if (!mounted) return -1;
    setState(() {
      _messages.add(StandMessage(
        _timeText,
        message,
        path,
        type,
        MessageCenter.right,
        0,
        size: size,
      ));
    });
    _scrollToBottom();
    return _messages.length - 1;
  }

  int _receiveFile(StandFile file) {
    if (!mounted) return -1;
    setState(() {
      _messages.add(StandMessage(
        _timeText,
        file.filename,
        file.filePath,
        file.fileType,
        MessageCenter.left,
        0,
        size: file.size,
      ));
    });
    _scrollToBottom();
    return _messages.length - 1;
  }

  void _receiveFileEnd(int index) {
    _updateProgress(1, index);
    _scrollToBottom();
  }

  void _receiveMsg(String message) {
    if (!mounted) return;
    setState(() {
      _messages.add(StandMessage(
        _timeText,
        message,
        '',
        StandType.text,
        MessageCenter.left,
        0,
      ));
    });
    _scrollToBottom();
  }

  void _updateProgress(double progress, int index) {
    if (!mounted || index < 0 || index >= _messages.length) return;
    setState(() {
      _messages[index].progress = progress.clamp(0.0, 1.0);
    });
  }

  void _markFailed(int index, String error) {
    if (!mounted || index < 0 || index >= _messages.length) return;
    setState(() {
      _messages[index].failed = true;
      _messages[index].error = error;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickFiles() async {
    if (_sendingFiles || _peerClosed) return;
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;

      final files = <({String path, String name})>[];
      for (final file in result.files) {
        final path = file.path;
        if (path == null) continue;
        files.add((path: path, name: file.name));
      }
      await _sendFilePaths(files);
    } catch (_) {
      if (mounted) _showSnack('无法选择文件');
    }
  }

  Future<void> _sendFilePaths(List<({String path, String name})> files) async {
    if (files.isEmpty || _peerClosed) return;
    if (_sendingFiles) {
      _showSnack('正在发送文件，请稍候');
      return;
    }
    setState(() => _sendingFiles = true);
    try {
      for (final file in files) {
        await _standHttpClient.uploadFile(file.path, file.name);
      }
    } catch (_) {
      if (mounted) _showSnack('文件发送失败');
    } finally {
      if (mounted) setState(() => _sendingFiles = false);
    }
  }

  void _onDrop(DropDoneDetails details) {
    if (mounted) setState(() => _dragging = false);
    if (_peerClosed) {
      _showSnack('连接已断开，无法发送文件');
      return;
    }

    final files = <({String path, String name})>[];
    var skipped = 0;
    for (final item in details.files) {
      if (item is DropItemDirectory || item.path.isEmpty) {
        skipped++;
        continue;
      }
      files.add((path: item.path, name: _fileName(item.path)));
    }

    if (files.isEmpty) {
      _showSnack('请拖入文件，暂不支持文件夹');
      return;
    }
    if (skipped > 0) _showSnack('已跳过 $skipped 个文件夹');
    unawaited(_sendFilePaths(files));
  }

  String _fileName(String path) {
    final index = path.lastIndexOf(RegExp(r'[/\\]'));
    final name = index >= 0 ? path.substring(index + 1) : path;
    return name.isEmpty ? path : name;
  }

  void _sendMsg() {
    final text = _textController.text.trim();
    if (text.isEmpty || _peerClosed) return;
    _textController.clear();
    _standHttpClient.sendMsg(text);
  }

  Future<void> _openReceiveFolder() async {
    final dir = await receiveDirectory();
    if (!mounted) return;
    if (Platform.isAndroid) {
      final opened = await AndroidBridge.openFolder(dir.path);
      if (!opened && mounted) _showSnack('无法打开文件管理器');
    } else {
      final result = await OpenFile.open(dir.path);
      if (result.type != ResultType.done && mounted) {
        _showSnack('无法打开接收目录');
      }
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final session = widget.session;

    final page = PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _confirmExit();
        if (shouldPop && mounted) {
          setState(() => _allowPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
      },
      child: Scaffold(
        backgroundColor:
            Color.lerp(colorScheme.surface, colorScheme.primaryContainer, 0.12),
        appBar: AppBar(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          titleSpacing: 4,
          title: Row(
            children: [
              deviceAvatar(session.peerType, colorScheme, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.peerName.isEmpty
                          ? session.peerAddress
                          : session.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    Row(
                      children: [
                        Icon(Icons.lock_rounded,
                            size: 12,
                            color: colorScheme.onPrimary.withOpacity(0.8)),
                        const SizedBox(width: 4),
                        Text(
                          '端到端加密 · ${session.peerAddress}',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onPrimary.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '打开接收目录',
              onPressed: _openReceiveFolder,
              icon: const Icon(Icons.folder_open_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _desktopConstrained(
                _messages.isEmpty
                    ? _buildEmptyState(colorScheme)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          final mine = message.center == MessageCenter.right;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Column(
                              crossAxisAlignment: mine
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 3),
                                  child: Text(
                                    message.time,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: colorScheme.onSurfaceVariant
                                          .withOpacity(0.7),
                                    ),
                                  ),
                                ),
                                Row(
                                  mainAxisAlignment: mine
                                      ? MainAxisAlignment.end
                                      : MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!mine) ...[
                                      deviceAvatar(
                                          session.peerType, colorScheme,
                                          size: 28),
                                      const SizedBox(width: 8),
                                    ],
                                    Flexible(
                                      child: MessageWidget(
                                        message: message.message,
                                        path: message.path,
                                        type: message.type,
                                        progress: message.progress,
                                        size: message.size,
                                        failed: message.failed,
                                        error: message.error,
                                        mine: mine,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
            if (_peerClosed) _buildClosedBanner(colorScheme),
            _buildInputBar(colorScheme),
          ],
        ),
      ),
    );

    if (!_isDesktop) return page;
    return DropTarget(
      onDragEntered: (_) {
        if (!_dragging) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (_dragging) setState(() => _dragging = false);
      },
      onDragDone: _onDrop,
      child: Stack(
        children: [
          page,
          if (_dragging) _buildDropOverlay(colorScheme),
        ],
      ),
    );
  }

  Widget _desktopConstrained(Widget child) {
    if (!_isDesktop) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: child,
      ),
    );
  }

  Widget _buildDropOverlay(ColorScheme colorScheme) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: colorScheme.scrim.withOpacity(0.3),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 34),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: colorScheme.primary, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.16),
                    blurRadius: 32,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.upload_file_rounded,
                      size: 46, color: colorScheme.primary),
                  const SizedBox(height: 14),
                  const Text(
                    '松开以发送文件',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '支持一次拖入多个文件',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: colorScheme.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.lock_rounded,
                  size: 38, color: colorScheme.primary),
            ),
            const SizedBox(height: 18),
            const Text(
              '已建立加密连接',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _isDesktop
                  ? '发送文字、选择或直接拖入文件\n所有内容仅在两台设备之间加密传输'
                  : '发送文字或选择文件开始传输\n所有内容仅在两台设备之间加密传输',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (_isDesktop) ...[
              const SizedBox(height: 20),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.drag_indicator_rounded,
                        size: 16, color: colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      '把文件拖到这个窗口即可发送',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildClosedBanner(ColorScheme colorScheme) {
    return _desktopConstrained(Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.link_off_rounded, size: 18, color: colorScheme.error),
          const SizedBox(width: 8),
          Text(
            '对方已断开连接',
            style: TextStyle(fontSize: 13, color: colorScheme.error),
          ),
        ],
      ),
    ));
  }

  Widget _buildInputBar(ColorScheme colorScheme) {
    return SafeArea(
      top: false,
      child: _desktopConstrained(Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(26),
          border:
              Border.all(color: colorScheme.outlineVariant.withOpacity(0.45)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: _isDesktop ? '选择文件（支持多选，也可直接拖入）' : '选择文件（支持多选）',
              onPressed: (_peerClosed || _sendingFiles) ? null : _pickFiles,
              icon: _sendingFiles
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
                    )
                  : const Icon(Icons.add_rounded),
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_peerClosed,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMsg(),
                decoration: InputDecoration(
                  hintText: _peerClosed
                      ? '连接已断开'
                      : (_isDesktop ? '输入消息，Enter 发送' : '发送消息...'),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: _peerClosed ? null : _sendMsg,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primary,
                disabledBackgroundColor:
                    colorScheme.outlineVariant.withOpacity(0.4),
              ),
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
            ),
            const SizedBox(width: 2),
          ],
        ),
      )),
    );
  }

  Future<bool> _confirmExit() async {
    final shouldPop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('退出后本次加密连接将断开，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    return shouldPop ?? false;
  }
}
