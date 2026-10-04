import 'package:flutter/material.dart';

class AppColors {
  static const Color white = Color(0xFFFCFBF8);
  static const Color black = Color(0xFF31250C);
  static const Color transparent = Colors.transparent;
  static const Color ink = Color(0xFF31250C);
  static const Color primary = Color(0xFFFF8F57);
  static const Color accent = Color(0xFFFFB957);
  static const Color background = Color(0xFFFCFBF8);
  static const Color surface = Color(0xFFFCFBF8);
  static const Color subtle = Color(0xFF31250C);
  static const Color muted = Color(0xFF625741);
  static const Color secondary = Color(0xFF625741);
  static const Color divider = Color(0xFFE3DED5);
  static const Color field = Color(0xFFF6F4EE);
  static const Color formField = Color(0xFFF6F4EE);
  static const Color chip = Color(0xFFF6F4EE);
  static const Color sheet = Color(0xFFF6F4EE);
  static const Color placeholder = Color(0xFF706A5C);
  static const Color placeholderIcon = Color(0xFF706A5C);
  static const Color open = Color(0xFF11AB1E);
  static const Color closed = Color(0xFFE3483A);
  static const Color mapBackground = Color(0xFFF2EFE9);
  static const Color photoBorder = Color(0xFFF6F4EE);
  static const Color activeText = Color(0xFF31250C);
  static const Color inactiveText = Color(0xFF625741);
  static const Color infoText = Color(0xFF625741);
  static const Color hintText = Color(0xFF625741);
  static const Color controlBorder = Color(0xFF625741);
  static const Color lightDivider = Color(0xFFF6F4EE);
  static const Color loading = Color(0xFF625741);
  static const Color mapMarker = Color(0xFF2F80ED);
  static const Color placeMarker = Color(0xFFFF8F57);
  static const Color shadow = Color(0x40000000);
  static const Color subtleShadow = Color(0x33000000);
  static const Color sheetShadow = Color(0x19000000);
  static const Color imageOverlay = Color(0x99000000);
  static const Color white54 = Color(0xFFFCFBF8);
  static const Color white70 = Color(0xFFFCFBF8);
  static const Color greyText = Color(0xFF625741);
}

class AppTypography {
  static const String fontFamily = 'Arial';
}

ThemeData buildTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: AppColors.background,
  canvasColor: AppColors.background,
  dividerColor: AppColors.divider,
  fontFamily: AppTypography.fontFamily,
);
