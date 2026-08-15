import 'package:flutter/material.dart';

/// ClipHist visual tokens — KDE Breeze light palette, ported 1:1 from
/// `src/styles/global.css` `:root`. The old app is light-only (no dark theme
/// in CSS), so this is a single light theme.
class CliphistColors {
  CliphistColors._();

  static const bgPrimary = Color(0xFFEFF0F1);
  static const bgSecondary = Color(0xFFFCFCFC);
  static const bgTertiary = Color(0xFFF1F2F3);
  static const bgHover = Color(0xFFE4E4E4);
  static const bgActive = Color(0xFFD8D9DA);
  static const textPrimary = Color(0xFF232629);
  static const textSecondary = Color(0xFF4D4F52);
  static const textTertiary = Color(0xFF76787D);
  static const accent = Color(0xFF3DAEE9);
  static const accentHover = Color(0xFF3498D6);
  static const border = Color(0xFFD5D7D8);

  // radii
  static const radius = 6.0;
  static const radiusSm = 4.0;
}

ThemeData cliphistTheme() {
  final scheme = const ColorScheme.light(
    primary: CliphistColors.accent,
    onPrimary: Colors.white,
    secondary: CliphistColors.accentHover,
    onSecondary: Colors.white,
    surface: CliphistColors.bgSecondary,
    onSurface: CliphistColors.textPrimary,
    error: Color(0xFFC0392B),
    outline: CliphistColors.border,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: CliphistColors.bgPrimary,
    cardColor: CliphistColors.bgSecondary,
    dividerColor: CliphistColors.border,
    splashFactory: NoSplash.splashFactory,
    // KDE Breeze is a flat, low-shadow UI — flatten Material's elevation cues.
    chipTheme: const ChipThemeData(
      backgroundColor: CliphistColors.bgTertiary,
      selectedColor: CliphistColors.accent,
      labelStyle: TextStyle(color: CliphistColors.textPrimary, fontSize: 12),
    ),
  );
}