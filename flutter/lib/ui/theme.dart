import 'dart:io';

import 'package:flutter/material.dart';

/// ClipHist visual tokens: neutral workspace surfaces with one blue accent.
/// Keeping the palette deliberately narrow prevents the header, filters and
/// content-type badges from competing for attention in a compact utility UI.
class CliphistColors {
  CliphistColors._();

  // ── Surfaces ────────────────────────────────────────────────────────────
  static const bgBase = Color(0xFFF5F7FA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSubtle = Color(0xFFF8FAFC);
  static const hover = Color(0xFFF1F5F9);
  static const selected = Color(0xFFEAF1FF);
  static const selectedRail = Color(0xFF356AE6);

  // ── Text ─────────────────────────────────────────────────────────────────
  static const textPrimary = Color(0xFF1D2733);
  static const textSecondary = Color(0xFF526171);
  static const textMuted = Color(0xFF8995A3);

  // ── Accent ───────────────────────────────────────────────────────────────
  static const accent = Color(0xFF356AE6);
  static const accentHover = Color(0xFF2858C8);
  static const accentSoft = Color(0xFFEAF1FF);
  static const brandStart = Color(0xFF356AE6);
  static const brandEnd = Color(0xFF356AE6);

  // ── Lines ────────────────────────────────────────────────────────────────
  static const border = Color(0xFFDEE5EC);
  static const borderSubtle = Color(0xFFE9EDF2);

  // ── Semantic ─────────────────────────────────────────────────────────────
  static const success = Color(0xFF27815C);
  static const warning = Color(0xFFB86A16);
  static const danger = Color(0xFFC43B45);

  // ── Per-type accents (used for the type dot + chip tint) ──────────────────
  static const typeAll = Color(0xFF64748B);
  static const typeText = Color(0xFF356AE6);
  static const typeLink = Color(0xFFC26A24);
  static const typeImage = Color(0xFF168393);
  static const typeShort = Color(0xFF7662B3);
  static const typeRich = Color(0xFFB55278);
  static const typeFiles = Color(0xFF4C7A45);

  // ── Radii ─────────────────────────────────────────────────────────────────
  static const radiusSm = 8.0;
  static const radius = 10.0;
  static const radiusLg = 12.0;
  static const radiusXl = 16.0;

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandStart, brandEnd],
  );

  static const cardShadow = <BoxShadow>[
    BoxShadow(color: Color(0x0A17212B), blurRadius: 10, offset: Offset(0, 3)),
  ];
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
  static const files = ClipType('files', '文件', CliphistColors.typeFiles);

  static const byKey = <ClipType>[all, image, files, text, link, short, rich];

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
  if (Platform.isMacOS) return 'PingFang SC';
  return null;
}

ThemeData cliphistTheme({bool acrylic = false}) {
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
    // Fully transparent fill made glyph AA composite onto the DWM blur and
    // read as 糊. ~82% tint still shows acrylic in the gutters, while text
    // on cards (opaque white) stays on a stable backing.
    scaffoldBackgroundColor: acrylic
        ? const Color(0xD0F5F7FA)
        : CliphistColors.bgBase,
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
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CliphistColors.accent,
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.standard,
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CliphistColors.radius),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: CliphistColors.surface,
      elevation: 16,
      shadowColor: const Color(0x4017212B),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CliphistColors.radiusXl),
      ),
      titleTextStyle: TextStyle(
        color: CliphistColors.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.3,
        fontFamily: font,
      ),
      contentTextStyle: TextStyle(
        color: CliphistColors.textSecondary,
        fontSize: 13,
        height: 1.45,
        fontFamily: font,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: const WidgetStatePropertyAll(Color(0x3D17212B)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: const WidgetStatePropertyAll(CliphistColors.surface),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
            side: const BorderSide(color: CliphistColors.borderSubtle),
          ),
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CliphistColors.textPrimary,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        height: 1.2,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(CliphistColors.surface),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? CliphistColors.accent
            : const Color(0xFFCBD2DA),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: CliphistColors.surfaceSubtle,
      selectedColor: CliphistColors.accentSoft,
      labelStyle: TextStyle(color: CliphistColors.textSecondary, fontSize: 12),
    ),
  );
}
