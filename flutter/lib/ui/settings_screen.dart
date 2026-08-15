import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_controller.dart';
import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/core/settings_store.dart' show SettingsPatch;
import '../state/providers.dart';
import '../util/toast.dart';
import 'theme.dart';

/// Settings panel, ported from `src/lib/settings-panel.svelte` (449 lines).
/// One scrollable column of setting cards; every change persists immediately
/// through `updateSettings` (which writes `settings.json` atomically in Rust)
/// and refreshes [settingsProvider] with the returned snapshot.
///
/// Side-effects deferred: global-hotkey registration and the double-tap
/// listener land in M7; `launch_at_startup` wiring for the autoStart toggle
/// is stubbed here and finalized with packaging paths in M10. Only
/// validate + persist + log happens in the Rust core for now (see M2 notes).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _hotkeyCtrl = TextEditingController();
  String _hotkeyError = '';

  @override
  void dispose() {
    _hotkeyCtrl.dispose();
    super.dispose();
  }

  ProviderContainer get _container => ClipHistController.instance.container;

  Future<void> _save(SettingsPatch patch, String successMsg) async {
    try {
      final updated = await api_settings.updateSettings(patch: patch);
      ref.read(settingsProvider.notifier).state = updated;
      showToast(_container, successMsg);
    } catch (e) {
      showToast(_container, '保存失败: $e');
    }
  }

  Future<void> _onHotkeySubmit() async {
    final value = _hotkeyCtrl.text.trim();
    setState(() => _hotkeyError = '');
    if (value.isEmpty) return;
    try {
      final valid = api_settings.validateHotkey(hotkey: value);
      if (!valid) {
        setState(() => _hotkeyError = '格式错误，例如：Ctrl+Shift+V');
        return;
      }
      await _save(SettingsPatch(hotkey: value), '快捷键已生效');
    } catch (e) {
      showToast(_container, '保存失败: $e');
    }
  }

  Future<void> _zoomDelta(int step) async {
    final s = ref.read(settingsProvider);
    final current = (s.zoomLevel * 100).round();
    final next = (current + step).clamp(50, 200);
    if (next == current) return;
    await _save(
      SettingsPatch(zoomLevel: next / 100.0),
      '缩放已调整',
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final helper = ref.watch(helperConnectedProvider);

    // Keep the hotkey field in sync when the panel opens / settings refresh.
    if (_hotkeyCtrl.text != s.hotkey && _hotkeyError.isEmpty) {
      _hotkeyCtrl.text = s.hotkey;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(onClose: () => ref.read(settingsOpenProvider.notifier).state = false),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _ToggleCard(
                label: '关闭时最小化到托盘',
                desc: '关闭窗口时程序继续在后台运行',
                value: s.closeToTray,
                onChanged: (v) => _save(SettingsPatch(closeToTray: v), '设置已保存'),
              ),
              _ToggleCard(
                label: '静默启动',
                desc: '启动时自动隐藏到托盘后台运行',
                value: s.silentStart,
                onChanged: (v) => _save(SettingsPatch(silentStart: v), '设置已保存'),
              ),
              _ToggleCard(
                label: '开机自动启动',
                desc: '系统启动时自动运行 ClipHist',
                value: s.autoStart,
                onChanged: (v) {
                  ClipHistController.instance.applyAutoStart(v);
                  _save(SettingsPatch(autoStart: v), '设置已保存');
                },
              ),
              _ZoomCard(
                percent: (s.zoomLevel * 100).round(),
                onDown: () => _zoomDelta(-10),
                onUp: () => _zoomDelta(10),
              ),
              _HotkeyCard(
                controller: _hotkeyCtrl,
                error: _hotkeyError,
                onSubmit: _onHotkeySubmit,
              ),
              _DoubleTapCard(
                value: s.doubleTapKey,
                helperConnected: helper,
                onChanged: (v) =>
                    _save(SettingsPatch(doubleTapKey: v), '双击快捷键已保存'),
              ),
              _RetentionCard(
                value: s.retentionDays,
                onChanged: (v) =>
                    _save(SettingsPatch(retentionDays: v), '设置已保存'),
              ),
              const _AboutCard(),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Cards ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 16, right: 8),
      color: CliphistColors.bgSecondary,
      child: Row(
        children: [
          const Text(
            '设置',
            style: TextStyle(
              color: CliphistColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: CliphistColors.textSecondary,
            splashRadius: 14,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({required this.info, required this.trailing});
  final Widget info;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CliphistColors.bgSecondary,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: info),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.label, required this.desc, this.extra});
  final String label;
  final String desc;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: CliphistColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          desc,
          style: const TextStyle(
            color: CliphistColors.textTertiary,
            fontSize: 11,
          ),
        ),
        if (extra != null) ...[const SizedBox(height: 2), extra!],
      ],
    );
  }
}

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.label,
    required this.desc,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String desc;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      info: _Info(label: label, desc: desc),
      trailing: Switch(
        value: value,
        activeThumbColor: const Color(0xFF4F46E5),
        onChanged: onChanged,
      ),
    );
  }
}

class _ZoomCard extends StatelessWidget {
  const _ZoomCard({
    required this.percent,
    required this.onDown,
    required this.onUp,
  });

  final int percent;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      info: const _Info(label: '窗口缩放', desc: '调整界面显示大小'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(icon: Icons.remove, onTap: onDown),
          Container(
            width: 45,
            alignment: Alignment.center,
            child: Text(
              '$percent%',
              style: const TextStyle(
                color: CliphistColors.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          _ZoomBtn(icon: Icons.add, onTap: onUp),
        ],
      ),
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  const _ZoomBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CliphistColors.bgTertiary,
          border: Border.all(color: CliphistColors.border),
          borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        ),
        child: Icon(icon, size: 16, color: CliphistColors.textPrimary),
      ),
    );
  }
}

class _HotkeyCard extends StatelessWidget {
  const _HotkeyCard({
    required this.controller,
    required this.error,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String error;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      info: _Info(
        label: '全局快捷键',
        desc: '唤醒窗口的快捷键',
        extra: error.isNotEmpty
            ? Text(
                error,
                style: const TextStyle(color: Color(0xFFDC2626), fontSize: 11),
              )
            : null,
      ),
      trailing: SizedBox(
        width: 120,
        child: TextField(
          controller: controller,
          onSubmitted: (_) => onSubmit(),
          textInputAction: TextInputAction.done,
          style: const TextStyle(
            color: CliphistColors.textPrimary,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Ctrl+Shift+V',
            hintStyle: const TextStyle(
              color: CliphistColors.textTertiary,
              fontSize: 12,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            filled: true,
            fillColor: CliphistColors.bgTertiary,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
              borderSide: const BorderSide(color: CliphistColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
              borderSide: const BorderSide(color: CliphistColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
              borderSide:
                  const BorderSide(color: CliphistColors.accent, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoubleTapCard extends StatelessWidget {
  const _DoubleTapCard({
    required this.value,
    required this.helperConnected,
    required this.onChanged,
  });

  final String value;
  final bool helperConnected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      info: _Info(
        label: '双击快捷键',
        desc: '快速双击指定键唤醒窗口',
        extra: value.isNotEmpty
            ? Text(
                helperConnected ? '已授权' : 'Linux 下首次使用需授权',
                style: TextStyle(
                  color: helperConnected
                      ? const Color(0xFF22C55E)
                      : CliphistColors.textTertiary,
                  fontSize: 11,
                ),
              )
            : null,
      ),
      trailing: _Select(
        value: value,
        items: const [
          ('', '禁用'),
          ('Ctrl', 'Ctrl'),
          ('Shift', 'Shift'),
          ('Alt', 'Alt'),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _RetentionCard extends StatelessWidget {
  const _RetentionCard({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      info: const _Info(label: '历史记录保存时长', desc: '超过设定时间的记录将自动清理'),
      trailing: _Select(
        value: value.toString(),
        items: const [
          ('1', '1 天'),
          ('3', '3 天'),
          ('7', '7 天'),
          ('30', '30 天'),
          ('0', '永久'),
        ],
        onChanged: (s) => onChanged(int.parse(s)),
      ),
    );
  }
}

class _Select extends StatelessWidget {
  const _Select({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        style: const TextStyle(
          color: CliphistColors.textPrimary,
          fontSize: 12,
        ),
        dropdownColor: CliphistColors.bgSecondary,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          filled: true,
          fillColor: CliphistColors.bgTertiary,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide: const BorderSide(color: CliphistColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide: const BorderSide(color: CliphistColors.border),
          ),
        ),
        items: items
            .map((i) => DropdownMenuItem(value: i.$1, child: Text(i.$2)))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    // Version injection (sed into pubspec) lands in M10; show a placeholder
    // until then.
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(12),
      child: const _Info(
        label: '关于 ClipHist',
        desc: '版本 dev · 剪贴板历史管理器',
      ),
    );
  }
}