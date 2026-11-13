import 'package:flutter/material.dart';

IconData deviceIconData(String deviceType) {
  switch (deviceType) {
    case 'Android':
      return Icons.android;
    case 'iOS':
    case 'MacOS':
      return Icons.apple;
    case 'Windows':
      return Icons.window_rounded;
    case 'Linux':
      return Icons.computer_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

Color deviceColor(String deviceType, ColorScheme colorScheme) {
  switch (deviceType) {
    case 'Android':
      return const Color(0xFF3DDC84);
    case 'iOS':
    case 'MacOS':
      return const Color(0xFF8E8E93);
    case 'Windows':
      return const Color(0xFF4C8BF5);
    case 'Linux':
      return const Color(0xFF9C6ADE);
    default:
      return colorScheme.primary;
  }
}

Widget deviceAvatar(String deviceType, ColorScheme colorScheme,
    {double size = 46}) {
  final color = deviceColor(deviceType, colorScheme);
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      shape: BoxShape.circle,
    ),
    alignment: Alignment.center,
    child: Icon(deviceIconData(deviceType), color: color, size: size * 0.5),
  );
}
