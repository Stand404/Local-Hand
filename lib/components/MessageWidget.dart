// ignore_for_file: file_names
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

import '../core/android_bridge.dart';
import '../core/file_storage.dart';
import '../http/StandHttpServer.dart';

/// 单条消息/文件气泡。
class MessageWidget extends StatelessWidget {
  final String message;
  final String path;
  final StandType type;
  final double progress;
  final int size;
  final bool failed;
  final String? error;
  final bool mine;

  const MessageWidget({
    super.key,
    required this.message,
    required this.path,
    required this.type,
    required this.progress,
    required this.size,
    required this.mine,
    this.failed = false,
    this.error,
  });

  bool get _completed => progress >= 1;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (type == StandType.text) {
      return GestureDetector(
        onLongPressStart: (details) =>
            _showMenu(context, details.globalPosition),
        onSecondaryTapUp: (details) =>
            _showMenu(context, details.globalPosition),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: mine ? colorScheme.primary : colorScheme.surface,
            borderRadius: _bubbleRadius(),
            border: mine
                ? null
                : Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Text(
            message,
            style: TextStyle(
              fontSize: 15,
              height: 1.35,
              color: mine ? colorScheme.onPrimary : colorScheme.onSurface,
            ),
          ),
        ),
      );
    }

    return MouseRegion(
      cursor: _completed ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onLongPressStart: (details) =>
            _showMenu(context, details.globalPosition),
        onSecondaryTapUp: (details) =>
            _showMenu(context, details.globalPosition),
        onTap: _completed ? () => _openFile(context) : null,
        child: Container(
          width: 272,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine
                ? colorScheme.primaryContainer.withValues(alpha: 0.7)
                : colorScheme.surface,
            borderRadius: _bubbleRadius(),
            border: Border.all(
              color: mine
                  ? colorScheme.primary.withValues(alpha: 0.16)
                  : colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (type == StandType.image &&
                  _completed &&
                  File(path).existsSync()) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(path),
                    width: double.infinity,
                    height: 168,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fileIcon(colorScheme),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _statusText(),
                          style: TextStyle(
                            fontSize: 12,
                            color: failed
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_completed)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: failed ? colorScheme.error : Colors.green.shade500,
                    ),
                ],
              ),
              if (!_completed || failed) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: failed ? 1 : progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor:
                        colorScheme.outlineVariant.withValues(alpha: 0.35),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      failed ? colorScheme.error : colorScheme.primary,
                    ),
                  ),
                ),
              ],
              if (failed && error != null) ...[
                const SizedBox(height: 6),
                Text(
                  error!,
                  style: TextStyle(fontSize: 11, color: colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileIcon(ColorScheme colorScheme) {
    final (icon, color) = switch (type) {
      StandType.image => (Icons.image_rounded, const Color(0xFF7C5CFF)),
      StandType.audio => (Icons.audiotrack_rounded, const Color(0xFFEF8B3E)),
      StandType.video => (Icons.movie_rounded, const Color(0xFFE45C86)),
      StandType.document => (
          Icons.description_rounded,
          const Color(0xFF4C8BF5)
        ),
      StandType.program => (Icons.terminal_rounded, const Color(0xFF35B36F)),
      _ => (Icons.insert_drive_file_rounded, colorScheme.primary),
    };
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 21, color: color),
    );
  }

  String _statusText() {
    if (failed) return error ?? '传输失败';
    final sizeText = size > 0 ? formatBytes(size) : '';
    if (_completed) {
      return sizeText.isEmpty ? '已完成' : sizeText;
    }
    final percent = (progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    return sizeText.isEmpty ? '传输中 $percent%' : '$sizeText · $percent%';
  }

  BorderRadius _bubbleRadius() {
    return BorderRadius.circular(18);
  }

  Future<void> _openFile(BuildContext context) async {
    if (path.isEmpty || !File(path).existsSync()) {
      if (context.mounted) _snack(context, '文件不存在或已被移动');
      return;
    }
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done && context.mounted) {
      _snack(context, '无法打开该文件，请先安装对应的应用');
    }
  }

  void _showMenu(BuildContext context, Offset globalPosition) async {
    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(
        value: 'copyMsg',
        child: Text('复制文字'),
      ),
    ];
    if (path.isNotEmpty) {
      items.add(const PopupMenuItem<String>(
        value: 'copyPath',
        child: Text('复制完整路径'),
      ));
      items.add(const PopupMenuItem<String>(
        value: 'openFolder',
        child: Text('打开文件位置'),
      ));
    }

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: items,
    );
    if (!context.mounted || result == null) return;

    switch (result) {
      case 'copyMsg':
        await Clipboard.setData(ClipboardData(text: message));
        if (context.mounted) _snack(context, '文字已复制');
        break;
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: path));
        if (context.mounted) _snack(context, '路径已复制');
        break;
      case 'openFolder':
        await _openFolder(context);
        break;
    }
  }

  Future<void> _openFolder(BuildContext context) async {
    final separator =
        path.lastIndexOf('/') > path.lastIndexOf('\\') ? '/' : '\\';
    final index = path.lastIndexOf(separator);
    if (index <= 0) return;
    final folder = path.substring(0, index);

    if (Platform.isAndroid) {
      final opened = await AndroidBridge.openFolder(folder);
      if (!opened && context.mounted) {
        _snack(context, '无法打开文件管理器');
      }
      return;
    }

    final result = await OpenFile.open(folder);
    if (result.type != ResultType.done && context.mounted) {
      _snack(context, '无法打开文件夹');
    }
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
      ));
  }
}
