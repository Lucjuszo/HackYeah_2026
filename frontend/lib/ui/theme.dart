import 'package:flutter/material.dart';

class AppColors {
  static const Color ink = Color(0xFF111111);
  static const Color primary = Color(0xFF20252B);
  static const Color subtle = Color(0xFF4E4E4E);
  static const Color muted = Color(0xFF777777);
  static const Color divider = Color(0xFFD7D7D7);
  static const Color field = Color(0xFFDADADA);
  static const Color chip = Color(0xFFE2E2E2);
  static const Color sheet = Color(0xFFF0F0F0);
  static const Color placeholder = Color(0xFFD9D9D9);
  static const Color placeholderIcon = Color(0xFFB5B5B5);
  static const Color open = Color(0xFF2C7A45);
  static const Color closed = Color(0xFFB53131);
}

ThemeData buildTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary),
  scaffoldBackgroundColor: Colors.white,
  fontFamily: 'Arial',
);
