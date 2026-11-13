import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:localhand/core/theme_controller.dart';
import 'package:localhand/models/friends.dart';
import 'package:localhand/pages/home_page.dart';
import 'package:provider/provider.dart';

const Color _seedColor = Color(0xFF5F7FFF);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 调试期误触“显示基线”会让每行文字下方出现黄/绿横线，启动时强制关闭。
  debugPaintBaselinesEnabled = false;
  final themeController = await ThemeController.load();
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (context) => Friends()),
      ChangeNotifierProvider.value(value: themeController),
    ],
    child: const MyApp(),
  ));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'SourceHanSansCN',
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Local Hand',
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: context.watch<ThemeController>().mode,
      home: const HomePage(),
    );
  }
}
