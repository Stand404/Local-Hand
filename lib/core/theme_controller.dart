import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 保存用户选择的主题模式，默认跟随系统。
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode);

  static const _prefsKey = 'theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final mode = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return ThemeController._(mode);
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }
}
