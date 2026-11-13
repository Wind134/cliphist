import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_controller.dart';
import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/core/settings_store.dart' show SettingsPatch;
import '../state/providers.dart';
import '../update/update_service.dart';
import '../util/toast.dart';
import 'app_switch.dart';
import 'chrome.dart';
import 'kbd.dart';
import 'theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _recording = false;
  String _recordHint = '';
  bool _handlerAttached = false;

  @override
  void dispose() {
    _detachKeyHandler();
    if (_recording) {
      try {
        final current = ClipHistController.instance.container
            .read(settingsProvider)
            .hotkey;
        unawaited(ClipHistController.instance.applyHotkey(current));
      } catch (_) {}
    }
    super.dispose();
  }

  ProviderContainer get _container => ClipHistController.instance.container;

  Future<bool> _save(SettingsPatch patch, String successMsg) async {
    try {
      final updated = await api_settings.updateSettings(patch: patch);
      ref.read(settingsProvider.notifier).state = updated;
      showToast(_container, successMsg);
      return true;
    } catch (e) {
      showToast(_container, '保存失败: $e');
      return false;
    }
  }

  Future<void> _onAutoStartChanged(bool enabled) async {
    final previous = ref.read(settingsProvider).autoStart;
    try {
      await ClipHistController.instance.applyAutoStart(enabled);
      final saved = await _save(SettingsPatch(autoStart: enabled), '设置已保存');
      if (!saved) {
        await ClipHistController.instance.applyAutoStart(previous);
      }
    } catch (e) {
      showToast(_container, '开机启动设置失败: $e');
    }
  }

  Future<void> _onGameModeChanged(bool enabled) async {
    try {
      await ClipHistController.instance.setGameMode(enabled);
      showToast(_container, enabled ? '游戏模式已开启' : '游戏模式已关闭');
    } catch (e) {
      showToast(_container, '游戏模式设置失败: $e');
    }
  }

  Future<void> _zoomDelta(int step) async {
    final s = ref.read(settingsProvider);
    final current = (s.zoomLevel * 100).round();
    final next = (current + step).clamp(80, 150);
    if (next == current) return;
    await _save(SettingsPatch(zoomLevel: next / 100.0), '缩放已调整');
  }

  Future<void> _onAcrylicChanged(bool enabled) async {
    final saved = await _save(SettingsPatch(acrylicEnabled: enabled), '设置已保存');
    if (saved) {
      await ClipHistController.instance.applyAcrylic(enabled);
    }
  }

  Future<void> _applyHotkey(String value) async {
    final previous = ref.read(settingsProvider).hotkey;
    try {
      final valid = api_settings.validateHotkey(hotkey: value);
      if (!valid) {
        showToast(_container, '需要修饰键，例如：Ctrl+Shift+V');
        await ClipHistController.instance.applyHotkey(previous);
        return;
      }
      await ClipHistController.instance.applyHotkey(value);
      final saved = await _save(SettingsPatch(hotkey: value), '快捷键已生效');
      if (!saved) {
        await ClipHistController.instance.applyHotkey(previous);
      }
    } catch (e) {
      showToast(_container, '保存失败: $e');
      await ClipHistController.instance.applyHotkey(previous);
    }
  }

  Future<void> _startRecording() async {
    if (_recording) return;
    // OS RegisterHotKey swallows the combo before Flutter sees it.
    await ClipHistController.instance.suspendHotkey();
    if (!mounted) return;
    if (!_handlerAttached) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      _handlerAttached = true;
    }
    setState(() {
      _recording = true;
      _recordHint = '';
    });
  }

  Future<void> _stopRecording({String? apply}) async {
    _detachKeyHandler();
    if (mounted) {
      setState(() {
        _recording = false;
        _recordHint = '';
      });
    }
    if (apply != null) {
      await _applyHotkey(apply);
    } else {
      final current = ref.read(settingsProvider).hotkey;
      await ClipHistController.instance.applyHotkey(current);
    }
  }

  void _detachKeyHandler() {
    if (!_handlerAttached) return;
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _handlerAttached = false;
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!_recording) return false;
    // Swallow everything while recording so 1–9 / Esc don't hit the list.
    if (event is! KeyDownEvent) return true;
    final key = event.logicalKey;
    if (_isModifier(key)) return true;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_stopRecording());
      return true;
    }
    final label = _keyLabel(key);
    if (label == null) return true;
    final parts = _modifierParts();
    if (parts.isEmpty) {
      setState(() => _recordHint = '请先按住 Ctrl / Shift / Alt');
      return true;
    }
    parts.add(label);
    unawaited(_stopRecording(apply: parts.join('+')));
    return true;
  }

  static bool _isModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  static List<String> _modifierParts() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final parts = <String>[];
    if (pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.control)) {
      parts.add('Ctrl');
    }
    if (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight) ||
        pressed.contains(LogicalKeyboardKey.shift)) {
      parts.add('Shift');
    }
    if (pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight) ||
        pressed.contains(LogicalKeyboardKey.alt)) {
      parts.add('Alt');
    }
    if (pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.meta)) {
      parts.add(Platform.isMacOS ? 'Cmd' : 'Meta');
    }
    return parts;
  }

  static String? _keyLabel(LogicalKeyboardKey key) {
    final letters = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.keyA: 'A',
      LogicalKeyboardKey.keyB: 'B',
      LogicalKeyboardKey.keyC: 'C',
      LogicalKeyboardKey.keyD: 'D',
      LogicalKeyboardKey.keyE: 'E',
      LogicalKeyboardKey.keyF: 'F',
      LogicalKeyboardKey.keyG: 'G',
      LogicalKeyboardKey.keyH: 'H',
      LogicalKeyboardKey.keyI: 'I',
      LogicalKeyboardKey.keyJ: 'J',
      LogicalKeyboardKey.keyK: 'K',
      LogicalKeyboardKey.keyL: 'L',
      LogicalKeyboardKey.keyM: 'M',
      LogicalKeyboardKey.keyN: 'N',
      LogicalKeyboardKey.keyO: 'O',
      LogicalKeyboardKey.keyP: 'P',
      LogicalKeyboardKey.keyQ: 'Q',
      LogicalKeyboardKey.keyR: 'R',
      LogicalKeyboardKey.keyS: 'S',
      LogicalKeyboardKey.keyT: 'T',
      LogicalKeyboardKey.keyU: 'U',
      LogicalKeyboardKey.keyV: 'V',
      LogicalKeyboardKey.keyW: 'W',
      LogicalKeyboardKey.keyX: 'X',
      LogicalKeyboardKey.keyY: 'Y',
      LogicalKeyboardKey.keyZ: 'Z',
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.enter: 'Enter',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.backspace: 'Backspace',
      LogicalKeyboardKey.f1: 'F1',
      LogicalKeyboardKey.f2: 'F2',
      LogicalKeyboardKey.f3: 'F3',
      LogicalKeyboardKey.f4: 'F4',
      LogicalKeyboardKey.f5: 'F5',
      LogicalKeyboardKey.f6: 'F6',
      LogicalKeyboardKey.f7: 'F7',
      LogicalKeyboardKey.f8: 'F8',
      LogicalKeyboardKey.f9: 'F9',
      LogicalKeyboardKey.f10: 'F10',
      LogicalKeyboardKey.f11: 'F11',
      LogicalKeyboardKey.f12: 'F12',
    };
    final mapped = letters[key];
    if (mapped != null) return mapped;
    final k = key.keyLabel;
    if (k.length == 1 && RegExp(r'[A-Za-z0-9]').hasMatch(k)) {
      return k.toUpperCase();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final helper = ref.watch(helperConnectedProvider);
    final c = context.c;
    final trayLabel = Platform.isMacOS ? '菜单栏' : '系统托盘';
    final acrylicSupported = !Platform.isLinux;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTitleBar(
          prefix: IconBtn(
            key: const ValueKey('settings-close'),
            icon: LucideIcons.chevronLeft,
            tooltip: '返回 (Esc)',
            onTap: () => ref.read(settingsOpenProvider.notifier).state = false,
          ),
          leading: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '设置',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w600,
                color: c.text,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
            children: [
              SettingSection(
                title: '通用',
                children: [
                  SettingRow(
                    title: '关闭时最小化到$trayLabel',
                    subtitle: '关闭窗口时继续在后台运行',
                    trailing: AppSwitch(
                      value: s.closeToTray,
                      onChanged: (v) =>
                          _save(SettingsPatch(closeToTray: v), '设置已保存'),
                    ),
                  ),
                  SettingRow(
                    title: '静默启动',
                    subtitle: '启动时隐藏到$trayLabel',
                    trailing: AppSwitch(
                      value: s.silentStart,
                      onChanged: (v) =>
                          _save(SettingsPatch(silentStart: v), '设置已保存'),
                    ),
                  ),
                  SettingRow(
                    title: '开机自动启动',
                    subtitle: '登录系统后自动运行',
                    trailing: AppSwitch(
                      value: s.autoStart,
                      onChanged: _onAutoStartChanged,
                    ),
                  ),
                ],
              ),
              SettingSection(
                title: '界面',
                children: [
                  SettingRow(
                    title: '主题',
                    subtitle: '跟随系统或手动指定',
                    tag: '新增',
                    trailing: Segmented(
                      value: s.themeMode,
                      items: const [
                        ('system', '系统'),
                        ('light', '浅色'),
                        ('dark', '深色'),
                      ],
                      onChanged: (v) =>
                          _save(SettingsPatch(themeMode: v), '设置已保存'),
                    ),
                  ),
                  SettingRow(
                    title: '窗口缩放',
                    subtitle: '调整界面显示大小',
                    trailing: _Stepper(
                      percent: (s.zoomLevel * 100).round(),
                      onDown: () => _zoomDelta(-10),
                      onUp: () => _zoomDelta(10),
                    ),
                  ),
                  SettingRow(
                    title: '窗口自适应',
                    subtitle: '随窗口大小缩放，并记住位置',
                    trailing: AppSwitch(
                      value: s.windowAdaptive,
                      onChanged: (v) =>
                          _save(SettingsPatch(windowAdaptive: v), '设置已保存'),
                    ),
                  ),
                  SettingRow(
                    title: '亚克力背景',
                    subtitle: acrylicSupported
                        ? (Platform.isMacOS
                              ? '窗口使用系统 vibrancy'
                              : 'Windows 模糊材质')
                        : '需要合成器支持模糊',
                    trailing: AppSwitch(
                      value: s.acrylicEnabled,
                      onChanged: acrylicSupported ? _onAcrylicChanged : null,
                    ),
                  ),
                  SettingRow(
                    title: '列表密度',
                    subtitle: '标准 46px / 紧凑 34px',
                    tag: '新增',
                    trailing: Segmented(
                      value: s.listDensity,
                      items: const [('standard', '标准'), ('compact', '紧凑')],
                      onChanged: (v) =>
                          _save(SettingsPatch(listDensity: v), '设置已保存'),
                    ),
                  ),
                ],
              ),
              SettingSection(
                title: '快捷键',
                children: [
                  SettingRow(
                    title: '全局快捷键',
                    subtitle: '唤醒窗口的快捷键',
                    trailing: _HotkeyBox(
                      hotkey: s.hotkey,
                      recording: _recording,
                      hint: _recordHint,
                      onTap: () => unawaited(_startRecording()),
                    ),
                  ),
                  SettingRow(
                    title: '双击快捷键',
                    subtitle: s.doubleTapKey.isEmpty
                        ? '快速双击指定键唤醒窗口'
                        : helper
                        ? '已授权，双击 ${s.doubleTapKey} 唤醒'
                        : 'Linux 下首次使用需授权',
                    trailing: _Select(
                      value: s.doubleTapKey,
                      items: Platform.isMacOS
                          ? const [
                              ('', '禁用'),
                              ('Ctrl', '⌘ Command'),
                              ('Shift', '⇧ Shift'),
                              ('Alt', '⌥ Option'),
                            ]
                          : const [
                              ('', '禁用'),
                              ('Ctrl', 'Ctrl'),
                              ('Shift', 'Shift'),
                              ('Alt', 'Alt'),
                            ],
                      onChanged: (v) =>
                          _save(SettingsPatch(doubleTapKey: v), '双击快捷键已保存'),
                    ),
                  ),
                  SettingRow(
                    title: '游戏模式',
                    subtitle: '暂停双击唤醒，其它功能仍可用',
                    trailing: AppSwitch(
                      value: s.gameMode,
                      onChanged: _onGameModeChanged,
                    ),
                  ),
                ],
              ),
              SettingSection(
                title: '数据',
                children: [
                  SettingRow(
                    title: '历史记录保存时长',
                    subtitle: '超过设定时间的记录将自动清理',
                    trailing: _Select(
                      value: s.retentionDays.toString(),
                      items: const [
                        ('1', '1 天'),
                        ('3', '3 天'),
                        ('7', '7 天'),
                        ('30', '30 天'),
                        ('0', '永久'),
                      ],
                      onChanged: (v) => _save(
                        SettingsPatch(retentionDays: int.parse(v)),
                        '设置已保存',
                      ),
                    ),
                  ),
                ],
              ),
              const _AboutCard(),
            ],
          ),
        ),
      ],
    );
  }
}

class SettingSection extends StatelessWidget {
  const SettingSection({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: c.text3,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: c.bgSub,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: c.border),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.tag,
  });
  final String title;
  final String? subtitle;
  final Widget trailing;
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: c.text,
                          ),
                        ),
                      ),
                      if (tag != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.fromLTRB(5, 1, 5, 1),
                          decoration: BoxDecoration(
                            color: c.accentSoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tag!,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: c.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        subtitle!,
                        style: TextStyle(fontSize: 11.5, color: c.text3),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
              child: trailing,
            ),
          ],
        ),
      ),
    );
  }
}

class Segmented extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            GestureDetector(
              onTap: () => onChanged(item.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: item.$1 == value ? c.bg : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: item.$1 == value
                      ? const [
                          BoxShadow(
                            color: Color(0x1F000000),
                            blurRadius: 2,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  item.$2,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: item.$1 == value ? c.text : c.text2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.percent,
    required this.onDown,
    required this.onUp,
  });
  final int percent;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget btn(IconData icon, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 14, color: c.text2),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.borderStrong),
      ),
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            btn(LucideIcons.minus, onDown),
            SizedBox(
              width: 46,
              child: Text(
                '$percent%',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: c.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            btn(LucideIcons.plus, onUp),
          ],
        ),
      ),
    );
  }
}

class _HotkeyBox extends StatelessWidget {
  const _HotkeyBox({
    required this.hotkey,
    required this.recording,
    required this.onTap,
    this.hint = '',
  });
  final String hotkey;
  final bool recording;
  final VoidCallback onTap;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final label = recording ? (hint.isEmpty ? '按下新的快捷键…' : hint) : null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: recording ? c.accent : c.borderStrong),
          boxShadow: recording
              ? [BoxShadow(color: c.accentSoft, spreadRadius: 3, blurRadius: 0)]
              : null,
        ),
        child: recording
            ? Text(label!, style: TextStyle(fontSize: 12, color: c.accent))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final part in hotkey.split('+')) ...[
                    Kbd(part.trim()),
                    if (part != hotkey.split('+').last)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          '+',
                          style: TextStyle(fontSize: 11, color: c.text4),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _Select extends StatefulWidget {
  const _Select({
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String value;
  final List<(String, String)> items;
  final Future<bool> Function(String) onChanged;

  @override
  State<_Select> createState() => _SelectState();
}

class _SelectState extends State<_Select> {
  bool _saving = false;

  String get _label {
    for (final item in widget.items) {
      if (item.$1 == widget.value) return item.$2;
    }
    return widget.value;
  }

  Future<void> _pick(String value) async {
    if (value == widget.value || _saving) return;
    setState(() => _saving = true);
    await widget.onChanged(value);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MenuAnchor(
      consumeOutsideTap: true,
      alignmentOffset: const Offset(0, 6),
      builder: (context, controller, _) {
        return GestureDetector(
          onTap: _saving
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
          child: Container(
            height: 28,
            constraints: const BoxConstraints(minWidth: 96),
            padding: const EdgeInsets.only(left: 10, right: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: controller.isOpen ? c.accent : c.borderStrong,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: c.text,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(LucideIcons.chevronDown, size: 14, color: c.text3),
              ],
            ),
          ),
        );
      },
      menuChildren: [
        for (final item in widget.items)
          MenuItemButton(
            onPressed: _saving ? null : () => _pick(item.$1),
            child: Text(item.$2),
          ),
      ],
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final update = ref.watch(updateStateProvider);
    final checking = update.phase == UpdatePhase.checking;
    final downloading = update.phase == UpdatePhase.downloading;
    final applying = update.phase == UpdatePhase.applying;
    final busy = checking || downloading || applying;
    final version = update.currentVersion.isEmpty ? '…' : update.currentVersion;
    String status;
    Color? statusColor;
    if (checking) {
      status = '正在检查…';
    } else if (downloading) {
      status = '正在下载 ${(update.downloadProgress * 100).round()}%';
    } else if (applying) {
      status = Platform.isWindows ? '正在启动安装程序…' : '正在打开安装包…';
    } else if (update.hasUpdate) {
      status = '发现新版本 v${update.latestVersion}';
      statusColor = c.accent;
    } else if (update.phase == UpdatePhase.failed) {
      status = update.errorMessage.contains('403')
          ? '检查更新失败（GitHub 限制访问）'
          : '检查更新失败';
      statusColor = c.danger;
    } else if (update.phase == UpdatePhase.idle &&
        update.currentVersion.isNotEmpty &&
        !update.hasUpdate) {
      status = '✓ 已是最新版本';
      statusColor = c.success;
    } else {
      status = '版本 $version';
    }

    final actionLabel = downloading
        ? '${(update.downloadProgress * 100).round()}%'
        : applying
        ? '安装中'
        : update.hasUpdate
        ? (update.canInstallInApp ? '安装' : '下载')
        : '检查更新';

    return SettingSection(
      title: '关于',
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF5B74FF), Color(0xFF8E5BFF)],
                    ),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Image.asset('assets/icon/app.png'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'My ClipHist',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.text,
                        ),
                      ),
                      Text(
                        status,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: statusColor ?? c.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: busy
                      ? null
                      : update.hasUpdate
                      ? ClipHistController.instance.downloadAndInstallUpdate
                      : ClipHistController.instance.checkForUpdates,
                  child: Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.borderStrong),
                    ),
                    child: busy
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: c.text2,
                            ),
                          )
                        : Text(
                            actionLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: c.text2,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
