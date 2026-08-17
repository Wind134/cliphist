import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_controller.dart';
import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/core/settings_store.dart' show SettingsPatch;
import '../state/providers.dart';
import '../update/update_service.dart';
import '../util/toast.dart';
import 'theme.dart';

/// Settings panel, ported from `src/lib/settings-panel.svelte` (449 lines).
/// Modernized: one scrollable column of rounded cards with a leading icon,
/// a title + description, and the control on the trailing side. Every change
/// persists immediately through `updateSettings` (atomically in Rust) and
/// refreshes [settingsProvider] with the returned snapshot.
///
/// OS side effects are coordinated through [ClipHistController]: the native
/// hotkey and auto-start entry are applied with rollback, while Rust owns the
/// double-tap listener and persists the resulting preference atomically.
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

  Future<void> _onHotkeySubmit() async {
    final value = _hotkeyCtrl.text.trim();
    final previous = ref.read(settingsProvider).hotkey;
    setState(() => _hotkeyError = '');
    if (value.isEmpty) return;
    try {
      final valid = api_settings.validateHotkey(hotkey: value);
      if (!valid) {
        setState(() => _hotkeyError = '格式错误，例如：Ctrl+Shift+V');
        return;
      }
      await ClipHistController.instance.applyHotkey(value);
      final saved = await _save(SettingsPatch(hotkey: value), '快捷键已生效');
      if (!saved) {
        await ClipHistController.instance.applyHotkey(previous);
      }
    } catch (e) {
      showToast(_container, '保存失败: $e');
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

  Future<void> _zoomDelta(int step) async {
    final s = ref.read(settingsProvider);
    final current = (s.zoomLevel * 100).round();
    final next = (current + step).clamp(50, 200);
    if (next == current) return;
    await _save(SettingsPatch(zoomLevel: next / 100.0), '缩放已调整');
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final helper = ref.watch(helperConnectedProvider);

    // Keep the hotkey field in sync when the panel opens / settings refresh.
    if (_hotkeyCtrl.text != s.hotkey && _hotkeyError.isEmpty) {
      _hotkeyCtrl.text = s.hotkey;
    }

    return Container(
      color: CliphistColors.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            onClose: () =>
                ref.read(settingsOpenProvider.notifier).state = false,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
              children: [
                _SectionLabel('通用'),
                _ToggleCard(
                  icon: Icons.minimize_rounded,
                  label: '关闭时最小化到托盘',
                  desc: '关闭窗口时程序继续在后台运行',
                  value: s.closeToTray,
                  onChanged: (v) =>
                      _save(SettingsPatch(closeToTray: v), '设置已保存'),
                ),
                _ToggleCard(
                  icon: Icons.visibility_off_rounded,
                  label: '静默启动',
                  desc: '启动时自动隐藏到托盘后台运行',
                  value: s.silentStart,
                  onChanged: (v) =>
                      _save(SettingsPatch(silentStart: v), '设置已保存'),
                ),
                _ToggleCard(
                  icon: Icons.power_settings_new_rounded,
                  label: '开机自动启动',
                  desc: '系统启动时自动运行 ClipHist',
                  value: s.autoStart,
                  onChanged: _onAutoStartChanged,
                ),
                _SectionLabel('界面'),
                _ZoomCard(
                  percent: (s.zoomLevel * 100).round(),
                  onDown: () => _zoomDelta(-10),
                  onUp: () => _zoomDelta(10),
                ),
                _SectionLabel('快捷键'),
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
                _SectionLabel('数据'),
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
      ),
    );
  }
}

// ── Header / labels / cards ──────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 62),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: const BoxDecoration(
        color: CliphistColors.surface,
        border: Border(bottom: BorderSide(color: CliphistColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CliphistColors.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.tune_rounded,
              size: 19,
              color: CliphistColors.accent,
            ),
          ),
          const SizedBox(width: 11),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '偏好设置',
                  style: TextStyle(
                    color: CliphistColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '自定义你的剪贴板工作流',
                  style: TextStyle(
                    color: CliphistColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            color: CliphistColors.textSecondary,
            style: IconButton.styleFrom(
              backgroundColor: CliphistColors.surfaceSubtle,
              side: const BorderSide(color: CliphistColors.borderSubtle),
            ),
            splashRadius: 16,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: CliphistColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.icon,
    required this.info,
    required this.trailing,
  });
  final IconData icon;
  final Widget info;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final stacked = constraints.maxWidth < 340 || scale > 1.35;
        final details = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _LeadingIcon(icon: icon),
            const SizedBox(width: 12),
            Expanded(child: info),
          ],
        );
        return Container(
          margin: const EdgeInsets.only(bottom: 7),
          padding: const EdgeInsets.fromLTRB(12, 12, 11, 12),
          decoration: BoxDecoration(
            color: CliphistColors.surface,
            borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
            border: Border.all(color: CliphistColors.borderSubtle),
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: trailing),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 12),
                    trailing,
                  ],
                ),
        );
      },
    );
  }
}

class _LeadingIcon extends StatelessWidget {
  const _LeadingIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: CliphistColors.accentSoft,
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
      ),
      child: Icon(icon, size: 18, color: CliphistColors.accent),
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
            color: CliphistColors.textMuted,
            fontSize: 11.5,
            height: 1.3,
          ),
        ),
        if (extra != null) ...[const SizedBox(height: 4), extra!],
      ],
    );
  }
}

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      icon: icon,
      info: _Info(label: label, desc: desc),
      trailing: SizedBox(
        height: 28,
        child: Switch(value: value, onChanged: onChanged),
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
      icon: Icons.format_size_rounded,
      info: const _Info(label: '窗口缩放', desc: '调整界面显示大小'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(icon: Icons.remove_rounded, onTap: onDown),
          Container(
            width: 52,
            alignment: Alignment.center,
            child: Text(
              '$percent%',
              style: const TextStyle(
                color: CliphistColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _ZoomBtn(icon: Icons.add_rounded, onTap: onUp),
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
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CliphistColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        ),
        child: Icon(icon, size: 18, color: CliphistColors.textSecondary),
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
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return _CardShell(
      icon: Icons.keyboard_rounded,
      info: _Info(
        label: '全局快捷键',
        desc: '唤醒窗口的快捷键',
        extra: error.isNotEmpty
            ? Text(
                error,
                style: const TextStyle(
                  color: CliphistColors.danger,
                  fontSize: 11,
                ),
              )
            : null,
      ),
      trailing: SizedBox(
        width: scale > 1.35 ? 200 : 130,
        child: _Field(
          controller: controller,
          onSubmit: onSubmit,
          hint: 'Ctrl+Shift+V',
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.onSubmit,
    required this.hint,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onSubmitted: (_) => onSubmit(),
      textInputAction: TextInputAction.done,
      style: const TextStyle(color: CliphistColors.textPrimary, fontSize: 12),
      textAlign: TextAlign.center,
      cursorColor: CliphistColors.accent,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(
          color: CliphistColors.textMuted,
          fontSize: 12,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        filled: true,
        fillColor: CliphistColors.surfaceSubtle,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
          borderSide: const BorderSide(
            color: CliphistColors.accent,
            width: 1.5,
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
      icon: Icons.touch_app_rounded,
      info: _Info(
        label: '双击快捷键',
        desc: '快速双击指定键唤醒窗口',
        extra: value.isNotEmpty
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    helperConnected
                        ? Icons.check_circle
                        : Icons.info_outline_rounded,
                    size: 12,
                    color: helperConnected
                        ? CliphistColors.success
                        : CliphistColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      helperConnected ? '已授权' : 'Linux 下首次使用需授权',
                      style: TextStyle(
                        color: helperConnected
                            ? CliphistColors.success
                            : CliphistColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
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
      icon: Icons.schedule_rounded,
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
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(
      width: scale > 1.35 ? 200 : 130,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        style: const TextStyle(color: CliphistColors.textPrimary, fontSize: 12),
        dropdownColor: CliphistColors.surface,
        icon: const Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 18,
          color: CliphistColors.textMuted,
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
          filled: true,
          fillColor: CliphistColors.surfaceSubtle,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
            borderSide: BorderSide.none,
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

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateStateProvider);
    final checking = update.phase == UpdatePhase.checking;
    final version = update.currentVersion.isEmpty
        ? '版本信息读取中'
        : 'v${update.currentVersion}';
    final subtitle = update.hasUpdate
        ? '发现新版本 v${update.latestVersion}'
        : update.phase == UpdatePhase.failed
        ? update.errorMessage
        : '剪贴板历史管理器 · $version';
    final details = Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CliphistColors.accentSoft,
            borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
          ),
          child: const Icon(
            Icons.layers_rounded,
            size: 18,
            color: CliphistColors.accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ClipHist',
                style: TextStyle(
                  color: CliphistColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: update.hasUpdate
                      ? CliphistColors.accent
                      : update.phase == UpdatePhase.failed
                      ? CliphistColors.danger
                      : CliphistColors.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final action = FilledButton.tonalIcon(
      onPressed: checking
          ? null
          : update.hasUpdate
          ? ClipHistController.instance.openLatestRelease
          : ClipHistController.instance.checkForUpdates,
      icon: checking
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              update.hasUpdate
                  ? Icons.open_in_new_rounded
                  : Icons.refresh_rounded,
            ),
      label: Text(update.hasUpdate ? '下载' : '检查更新'),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final stacked = constraints.maxWidth < 360 || scale > 1.35;
        return Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          decoration: BoxDecoration(
            color: CliphistColors.surface,
            borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
            border: Border.all(color: CliphistColors.borderSubtle),
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 10),
                    action,
                  ],
                ),
        );
      },
    );
  }
}
