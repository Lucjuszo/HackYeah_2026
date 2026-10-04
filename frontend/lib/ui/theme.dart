import 'package:flutter/material.dart';

class AppColors {
  static const Color white = Colors.white;
  static const Color black = Colors.black;
  static const Color transparent = Colors.transparent;
  static const Color ink = Color(0xFF29251F);
  static const Color primary = Color(0xFFFFA94D);
  static const Color accent = Color(0xFFFFB85C);
  static const Color background = Color(0xFFFFFCF7);
  static const Color surface = Color(0xFFFFFEFB);
  static const Color subtle = Color(0xFF5C564D);
  static const Color muted = Color(0xFF817A70);
  static const Color secondary = Color(0xFF8A8A8A);
  static const Color divider = Color(0xFFE3DED5);
  static const Color field = Color(0xFFE4E1DD);
  static const Color formField = Color(0xFFF5EEDD);
  static const Color chip = Color(0xFFEAE7E2);
  static const Color sheet = Color(0xFFF6F1E9);
  static const Color placeholder = Color(0xFFDAD8D5);
  static const Color placeholderIcon = Color(0xFFB3AEA5);
  static const Color open = Color(0xFF4D9959);
  static const Color closed = Color(0xFFC85246);
  static const Color mapBackground = Color(0xFFF2EFE9);
  static const Color photoBorder = Color(0xFFE8DCC5);
  static const Color activeText = Color(0xFF222222);
  static const Color inactiveText = Color(0xFF8A8A8A);
  static const Color infoText = Color(0xFF656565);
  static const Color hintText = Color(0xFF7A7A7A);
  static const Color controlBorder = Color(0xFF858585);
  static const Color lightDivider = Color(0xFFE6E6E6);
  static const Color loading = Color(0xFFB8B8B8);
  static const Color mapMarker = Color(0xFF2F80ED);
  static const Color placeMarker = Color(0xFFFF8F57);
  static const Color shadow = Color(0x40000000);
  static const Color subtleShadow = Color(0x33000000);
  static const Color sheetShadow = Color(0x19000000);
  static const Color imageOverlay = Color(0x99000000);
  static const Color white54 = Colors.white54;
  static const Color white70 = Colors.white70;
  static const Color greyText = Color(0xFF757575);
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
