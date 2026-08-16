import 'dart:io';

import 'package:flutter/material.dart';

/// ClipHist visual tokens — a refined modern light theme. Departing from the
/// 1:1 KDE-Breeze port (M3): the old palette read as cramped and "abstract"
/// once Flutter rendered it on Windows (Roboto for Latin + a thin CJK
/// fallback, all at 10–11px). This system widens the rhythm, softens the
/// surfaces, and routes text through a platform CJK font so Chinese is crisp.
class CliphistColors {
  CliphistColors._();

  // ── Surfaces ────────────────────────────────────────────────────────────
  static const bgBase = Color(0xFFF6F7F9); // app background
  static const surface = Color(0xFFFFFFFF); // cards, search field
  static const surfaceSubtle = Color(0xFFF1F3F6); // chips, badges, inputs
  static const hover = Color(0xFFECEFF3);
  static const selected = Color(0xFFE8EEFF); // soft accent tint
  static const selectedRail = Color(0xFF4F7CFF);

  // ── Text ─────────────────────────────────────────────────────────────────
  static const textPrimary = Color(0xFF1B1F24);
  static const textSecondary = Color(0xFF555B64);
  static const textMuted = Color(0xFF939AA3);

  // ── Accent ───────────────────────────────────────────────────────────────
  static const accent = Color(0xFF4F7CFF);
  static const accentHover = Color(0xFF3A66F0);
  static const accentSoft = Color(0xFFE8EEFF);

  // ── Lines ────────────────────────────────────────────────────────────────
  static const border = Color(0xFFE6E9ED);
  static const borderSubtle = Color(0xFFEEF1F4);

  // ── Semantic ─────────────────────────────────────────────────────────────
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFD97706);
  static const danger = Color(0xFFDC2626);

  // ── Per-type accents (used for the type dot + chip tint) ──────────────────
  static const typeAll = Color(0xFF64748B);
  static const typeText = Color(0xFF2563EB);
  static const typeLink = Color(0xFFDC2626);
  static const typeImage = Color(0xFF0891B2);
  static const typeShort = Color(0xFF7C3AED);
  static const typeRich = Color(0xFFDB2777);

  // ── Radii ─────────────────────────────────────────────────────────────────
  static const radiusSm = 8.0;
  static const radius = 10.0;
  static const radiusLg = 14.0;
}

/// Per-type color + label, shared by the category chips and the row dot.
class ClipType {
  final String key;
  final String label;
  final Color color;
  const ClipType(this.key, this.label, this.color);

  static const all = ClipType('all', '全部', CliphistColors.typeAll);
  static const image = ClipType('image', '图片', CliphistColors.typeImage);
  static const text = ClipType('text', '文本', CliphistColors.typeText);
  static const link = ClipType('link', '链接', CliphistColors.typeLink);
  static const short = ClipType('short', '短文本', CliphistColors.typeShort);
  static const rich = ClipType('rich', '富文本', CliphistColors.typeRich);

  static const byKey = <ClipType>[
    all,
    image,
    text,
    link,
    short,
    rich,
  ];

  static ClipType? of(String key) {
    for (final t in byKey) {
      if (t.key == key) return t;
    }
    return null;
  }
}

/// A CJK-capable platform font so Chinese renders crisply on Windows instead
/// of the bundled-Roboto + thin-fallback mix that read as "抽象". `Microsoft
/// YaHei UI` carries Latin glyphs too, so a single family covers both scripts
/// uniformly. Linux/macOS keep Flutter's default — their fontconfig/CoreText
/// fallback already resolves CJK cleanly.
String? get _platformFont {
  if (Platform.isWindows) return 'Microsoft YaHei UI';
  return null;
}

ThemeData cliphistTheme() {
  final font = _platformFont;
  final scheme = const ColorScheme(
    brightness: Brightness.light,
    primary: CliphistColors.accent,
    onPrimary: Colors.white,
    secondary: CliphistColors.accentHover,
    onSecondary: Colors.white,
    surface: CliphistColors.surface,
    onSurface: CliphistColors.textPrimary,
    error: CliphistColors.danger,
    onError: Colors.white,
    outline: CliphistColors.border,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: font,
    scaffoldBackgroundColor: CliphistColors.bgBase,
    cardColor: CliphistColors.surface,
    dividerColor: CliphistColors.borderSubtle,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: CliphistColors.hover,
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        iconSize: WidgetStatePropertyAll(18),
        foregroundColor: WidgetStatePropertyAll(CliphistColors.textSecondary),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(CliphistColors.surface),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected)
              ? CliphistColors.accent
              : const Color(0xFFCBD2DA)),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: CliphistColors.surfaceSubtle,
      selectedColor: CliphistColors.accentSoft,
      labelStyle: TextStyle(
          color: CliphistColors.textSecondary, fontSize: 12),
    ),
  );
}