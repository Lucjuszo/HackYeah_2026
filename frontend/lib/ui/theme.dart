import 'package:flutter/material.dart';

class AppColors {
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
  fontFamily: 'Arial',
);
