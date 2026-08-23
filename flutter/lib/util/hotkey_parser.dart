import 'package:flutter/services.dart';
import 'package:hotkey_manager_platform_interface/hotkey_manager_platform_interface.dart';

/// Parse the exact shortcut grammar also accepted by the Rust settings
/// validator: one or more distinct modifiers followed by exactly one key.
HotKey parseHotKey(String shortcut) {
  final parts = shortcut
      .split('+')
      .map((part) => part.trim().toUpperCase())
      .toList();
  if (parts.any((part) => part.isEmpty)) {
    throw FormatException('无效的快捷键: $shortcut');
  }

  final modifiers = <HotKeyModifier>[];
  PhysicalKeyboardKey? key;
  for (final part in parts) {
    switch (part) {
      case 'COMMANDORCONTROL':
      case 'CMDORCTRL':
      case 'CTRL':
      case 'CONTROL':
        _addUniqueModifier(modifiers, HotKeyModifier.control, shortcut);
      case 'COMMAND':
      case 'CMD':
      case 'SUPER':
      case 'META':
      case 'WIN':
        _addUniqueModifier(modifiers, HotKeyModifier.meta, shortcut);
      case 'SHIFT':
        _addUniqueModifier(modifiers, HotKeyModifier.shift, shortcut);
      case 'ALT':
      case 'OPTION':
        _addUniqueModifier(modifiers, HotKeyModifier.alt, shortcut);
      default:
        if (key != null) throw FormatException('无效的快捷键: $shortcut');
        key = _physicalKey(part);
        if (key == null) throw FormatException('无效的快捷键: $shortcut');
    }
  }
  if (key == null || modifiers.isEmpty) {
    throw FormatException('无效的快捷键: $shortcut');
  }
  return HotKey(key: key, modifiers: modifiers, scope: HotKeyScope.system);
}

void _addUniqueModifier(
  List<HotKeyModifier> modifiers,
  HotKeyModifier modifier,
  String shortcut,
) {
  if (modifiers.contains(modifier)) {
    throw FormatException('无效的快捷键: $shortcut');
  }
  modifiers.add(modifier);
}

PhysicalKeyboardKey? _physicalKey(String value) {
  if (value.length == 1) {
    const letters = <String, PhysicalKeyboardKey>{
      'A': PhysicalKeyboardKey.keyA,
      'B': PhysicalKeyboardKey.keyB,
      'C': PhysicalKeyboardKey.keyC,
      'D': PhysicalKeyboardKey.keyD,
      'E': PhysicalKeyboardKey.keyE,
      'F': PhysicalKeyboardKey.keyF,
      'G': PhysicalKeyboardKey.keyG,
      'H': PhysicalKeyboardKey.keyH,
      'I': PhysicalKeyboardKey.keyI,
      'J': PhysicalKeyboardKey.keyJ,
      'K': PhysicalKeyboardKey.keyK,
      'L': PhysicalKeyboardKey.keyL,
      'M': PhysicalKeyboardKey.keyM,
      'N': PhysicalKeyboardKey.keyN,
      'O': PhysicalKeyboardKey.keyO,
      'P': PhysicalKeyboardKey.keyP,
      'Q': PhysicalKeyboardKey.keyQ,
      'R': PhysicalKeyboardKey.keyR,
      'S': PhysicalKeyboardKey.keyS,
      'T': PhysicalKeyboardKey.keyT,
      'U': PhysicalKeyboardKey.keyU,
      'V': PhysicalKeyboardKey.keyV,
      'W': PhysicalKeyboardKey.keyW,
      'X': PhysicalKeyboardKey.keyX,
      'Y': PhysicalKeyboardKey.keyY,
      'Z': PhysicalKeyboardKey.keyZ,
      '0': PhysicalKeyboardKey.digit0,
      '1': PhysicalKeyboardKey.digit1,
      '2': PhysicalKeyboardKey.digit2,
      '3': PhysicalKeyboardKey.digit3,
      '4': PhysicalKeyboardKey.digit4,
      '5': PhysicalKeyboardKey.digit5,
      '6': PhysicalKeyboardKey.digit6,
      '7': PhysicalKeyboardKey.digit7,
      '8': PhysicalKeyboardKey.digit8,
      '9': PhysicalKeyboardKey.digit9,
    };
    return letters[value];
  }
  const named = <String, PhysicalKeyboardKey>{
    'SPACE': PhysicalKeyboardKey.space,
    'ENTER': PhysicalKeyboardKey.enter,
    'RETURN': PhysicalKeyboardKey.enter,
    'TAB': PhysicalKeyboardKey.tab,
    'ESC': PhysicalKeyboardKey.escape,
    'ESCAPE': PhysicalKeyboardKey.escape,
    'BACKSPACE': PhysicalKeyboardKey.backspace,
    'F1': PhysicalKeyboardKey.f1,
    'F2': PhysicalKeyboardKey.f2,
    'F3': PhysicalKeyboardKey.f3,
    'F4': PhysicalKeyboardKey.f4,
    'F5': PhysicalKeyboardKey.f5,
    'F6': PhysicalKeyboardKey.f6,
    'F7': PhysicalKeyboardKey.f7,
    'F8': PhysicalKeyboardKey.f8,
    'F9': PhysicalKeyboardKey.f9,
    'F10': PhysicalKeyboardKey.f10,
    'F11': PhysicalKeyboardKey.f11,
    'F12': PhysicalKeyboardKey.f12,
  };
  return named[value];
}
