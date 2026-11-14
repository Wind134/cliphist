import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Design tokens from the v2.2 prototype. Accessed as `context.c`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color bg, bgSub, surface, surfaceHover, border, borderStrong;
  final Color text, text2, text3, text4;
  final Color accent, accentHover, onAccent, accentSoft, selBorder;
  final Color rowSel, rowSelBorder, leadBg, leadBorder, imgHairline, hover;
  final Color danger, success, warn, winClose, kbdBg, kbdBorder;

  const AppColors({
    required this.bg,
    required this.bgSub,
    required this.surface,
    required this.surfaceHover,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.text2,
    required this.text3,
    required this.text4,
    required this.accent,
    required this.accentHover,
    required this.onAccent,
    required this.accentSoft,
    required this.selBorder,
    required this.rowSel,
    required this.rowSelBorder,
    required this.leadBg,
    required this.leadBorder,
    required this.imgHairline,
    required this.hover,
    required this.danger,
    required this.success,
    required this.warn,
    required this.winClose,
    required this.kbdBg,
    required this.kbdBorder,
  });

  static const light = AppColors(
    bg: Color(0xFFFFFFFF),
    bgSub: Color(0xFFF7F7F8),
    surface: Color(0xFFF2F2F4),
    surfaceHover: Color(0xFFEBEBEE),
    border: Color(0xFFE6E6EA),
    borderStrong: Color(0xFFD4D4DA),
    text: Color(0xFF18181B),
    text2: Color(0xFF52525B),
    text3: Color(0xFF8E8E96),
    text4: Color(0xFFB4B4BC),
    accent: Color(0xFF3D5AFE),
    accentHover: Color(0xFF2F4BEA),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x173D5AFE),
    selBorder: Color(0x593D5AFE),
    rowSel: Color(0x0F3D5AFE),
    rowSelBorder: Color(0x293D5AFE),
    leadBg: Color(0x06000000),
    leadBorder: Color(0x0F000000),
    imgHairline: Color(0x0F000000),
    hover: Color(0x0A000000),
    danger: Color(0xFFE5484D),
    success: Color(0xFF30A46C),
    warn: Color(0xFFF5A524),
    winClose: Color(0xFFC42B1C),
    kbdBg: Color(0xFFFFFFFF),
    kbdBorder: Color(0xFFD9D9DE),
  );

  static const dark = AppColors(
    bg: Color(0xFF1B1B1E),
    bgSub: Color(0xFF202024),
    surface: Color(0xFF26262A),
    surfaceHover: Color(0xFF2E2E33),
    border: Color(0xFF2F2F34),
    borderStrong: Color(0xFF3D3D44),
    text: Color(0xFFEDEDF0),
    text2: Color(0xFFA9A9B2),
    text3: Color(0xFF7A7A84),
    text4: Color(0xFF55555D),
    accent: Color(0xFF6E86FF),
    accentHover: Color(0xFF8296FF),
    onAccent: Color(0xFF0B0B10),
    accentSoft: Color(0x246E86FF),
    selBorder: Color(0x736E86FF),
    rowSel: Color(0x1A6E86FF),
    rowSelBorder: Color(0x386E86FF),
    leadBg: Color(0x08FFFFFF),
    leadBorder: Color(0x12FFFFFF),
    imgHairline: Color(0x14FFFFFF),
    hover: Color(0x0BFFFFFF),
    danger: Color(0xFFF2555A),
    success: Color(0xFF3DD68C),
    warn: Color(0xFFFFB224),
    winClose: Color(0xFFC42B1C),
    kbdBg: Color(0xFF2A2A2F),
    kbdBorder: Color(0xFF3A3A41),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? bgSub,
    Color? surface,
    Color? surfaceHover,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? text2,
    Color? text3,
    Color? text4,
    Color? accent,
    Color? accentHover,
    Color? onAccent,
    Color? accentSoft,
    Color? selBorder,
    Color? rowSel,
    Color? rowSelBorder,
    Color? leadBg,
    Color? leadBorder,
    Color? imgHairline,
    Color? hover,
    Color? danger,
    Color? success,
    Color? warn,
    Color? winClose,
    Color? kbdBg,
    Color? kbdBorder,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      bgSub: bgSub ?? this.bgSub,
      surface: surface ?? this.surface,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      text3: text3 ?? this.text3,
      text4: text4 ?? this.text4,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      selBorder: selBorder ?? this.selBorder,
      rowSel: rowSel ?? this.rowSel,
      rowSelBorder: rowSelBorder ?? this.rowSelBorder,
      leadBg: leadBg ?? this.leadBg,
      leadBorder: leadBorder ?? this.leadBorder,
      imgHairline: imgHairline ?? this.imgHairline,
      hover: hover ?? this.hover,
      danger: danger ?? this.danger,
      success: success ?? this.success,
      warn: warn ?? this.warn,
      winClose: winClose ?? this.winClose,
      kbdBg: kbdBg ?? this.kbdBg,
      kbdBorder: kbdBorder ?? this.kbdBorder,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return t < 0.5 ? this : other;
  }
}

extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>()!;
  double get textScale => MediaQuery.textScalerOf(this).scale(1);
  double sp(double px) => px * textScale;
}

/// Back-compat aliases used by a few tests and older call sites.
class CliphistColors {
  CliphistColors._();
  static const bgBase = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF2F2F4);
  static const textPrimary = Color(0xFF18181B);
  static const textSecondary = Color(0xFF52525B);
  static const textMuted = Color(0xFF8E8E96);
  static const accent = Color(0xFF3D5AFE);
  static const accentHover = Color(0xFF2F4BEA);
  static const accentSoft = Color(0x173D5AFE);
  static const danger = Color(0xFFE5484D);
  static const border = Color(0xFFE6E6EA);
  static const borderSubtle = Color(0xFFE6E6EA);
  static const hover = Color(0x0A000000);
  static const radiusSm = 6.0;
  static const radius = 8.0;
  static const radiusLg = 10.0;
}

abstract class Gap {
  static const xs = 4.0;
  static const sm = 6.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;
}

abstract class Radii {
  static const xs = 4.0;
  static const sm = 6.0;
  static const md = 8.0;
  static const lg = 10.0;
}

abstract class Sizes {
  static const titleBar = 40.0;
  static const search = 36.0;
  static const chip = 26.0;
  static const row = 46.0;
  static const rowCompact = 34.0;
  static const footer = 30.0;
  static const control = 28.0;
  static const iconBtn = 28.0;
  static const rowAction = 26.0;
  static const leadW = 34.0;
  static const leadH = 34.0;
  static const leadCompactW = 26.0;
  static const leadCompactH = 26.0;
  static const index = 20.0;
  static const timeCol = 64.0;
}

class ClipType {
  final String key;
  final String label;
  const ClipType(this.key, this.label);

  static const all = ClipType('all', '全部');
  static const image = ClipType('image', '图片');
  static const text = ClipType('text', '文本');
  static const link = ClipType('link', '链接');
  static const short = ClipType('short', '短文本');
  static const rich = ClipType('rich', '富文本');
  static const files = ClipType('files', '文件');

  static const byKey = <ClipType>[all, image, files, text, link, short, rich];

  static ClipType? of(String key) {
    for (final t in byKey) {
      if (t.key == key) return t;
    }
    return null;
  }
}

String? get _platformFont {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'Microsoft YaHei UI';
    case TargetPlatform.macOS:
      return null;
    default:
      return 'Noto Sans CJK SC';
  }
}

const _fontFallback = <String>[
  'PingFang SC',
  'Microsoft YaHei UI',
  'Noto Sans CJK SC',
  'Noto Sans SC',
];

const monoFamily = 'Cascadia Mono';
const monoFallback = <String>[
  'Consolas',
  'Cascadia Code',
  'JetBrains Mono',
  'SF Mono',
  'Microsoft YaHei UI',
  'Noto Sans CJK SC',
  'Noto Sans Mono CJK SC',
  'PingFang SC',
  'monospace',
];

ThemeData cliphistTheme({
  bool acrylic = false,
  Brightness brightness = Brightness.light,
}) {
  return buildTheme(brightness, acrylic: acrylic);
}

ThemeData buildTheme(Brightness b, {bool acrylic = false}) {
  final c = b == Brightness.light ? AppColors.light : AppColors.dark;
  final font = _platformFont;
  final onAccent = c.onAccent;
  final scheme = ColorScheme(
    brightness: b,
    primary: c.accent,
    onPrimary: onAccent,
    secondary: c.accent,
    onSecondary: onAccent,
    error: c.danger,
    onError: Colors.white,
    surface: c.bg,
    onSurface: c.text,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.bgSub,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceHover,
    onSurfaceVariant: c.text2,
    outline: c.borderStrong,
    outlineVariant: c.border,
  );

  final scaffold = acrylic
      ? (b == Brightness.light
            ? const Color(0xB8FAFAFC)
            : const Color(0xB81C1C20))
      : c.bg;

  TextStyle ts(
    double size,
    Color color, {
    FontWeight weight = FontWeight.w400,
    double height = 1.38,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      color: color,
      fontWeight: weight,
      fontFamily: font,
      fontFamilyFallback: _fontFallback,
      letterSpacing: letterSpacing,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffold,
    fontFamily: font,
    fontFamilyFallback: _fontFallback,
    textTheme: TextTheme(
      titleSmall: ts(13, c.text, weight: FontWeight.w600, height: 18 / 13),
      bodyMedium: ts(13, c.text, height: 18 / 13),
      bodySmall: ts(12, c.text2, weight: FontWeight.w500, height: 16 / 12),
      labelSmall: ts(11, c.text3, height: 15 / 11),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    splashFactory: NoSplash.splashFactory,
    hoverColor: c.hover,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    visualDensity: VisualDensity.compact,
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      textStyle: TextStyle(fontSize: 11.5, color: c.bg, height: 1.2),
      decoration: BoxDecoration(
        color: c.text,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.bg,
      elevation: 16,
      shadowColor: Colors.black38,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      titleTextStyle: ts(14, c.text, weight: FontWeight.w600, height: 1.3),
      contentTextStyle: ts(12.5, c.text2, height: 1.45),
    ),
    extensions: [c],
  );
}

bool get isMac => !kIsWeb && Platform.isMacOS;
bool get isLinux => !kIsWeb && Platform.isLinux;
bool get isWindows => !kIsWeb && Platform.isWindows;
