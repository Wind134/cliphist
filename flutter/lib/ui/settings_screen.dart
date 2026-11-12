import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_controller.dart';
import '../src/rust/api/settings.dart' as api_settings;
import '../src/rust/core/settings_store.dart' show SettingsPatch;
import '../state/providers.dart';
import '../update/update_service.dart';
import '../util/toast.dart';
import 'chrome.dart';
import 'theme.dart';

/// Settings as grouped inset lists (Win11 / iOS): one card per section, compact
/// rows with the control vertically centered. Every change persists through
/// `updateSettings` and refreshes [settingsProvider].
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
    final next = (current + step).clamp(50, 200);
    if (next == current) return;
    await _save(SettingsPatch(zoomLevel: next / 100.0), '缩放已调整');
  }

  Future<void> _onAcrylicChanged(bool enabled) async {
    final saved = await _save(SettingsPatch(acrylicEnabled: enabled), '设置已保存');
    if (saved) {
      await ClipHistController.instance.applyAcrylic(enabled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final helper = ref.watch(helperConnectedProvider);

    if (_hotkeyCtrl.text != s.hotkey && _hotkeyError.isEmpty) {
      _hotkeyCtrl.text = s.hotkey;
    }

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            onClose: () =>
                ref.read(settingsOpenProvider.notifier).state = false,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              children: [
                _SettingsGroup(
                  title: '通用',
                  children: [
                    _SettingsRow(
                      icon: Icons.minimize_rounded,
                      title: '关闭时最小化到托盘',
                      subtitle: '关闭窗口时继续在后台运行',
                      trailing: Switch(
                        value: s.closeToTray,
                        onChanged: (v) =>
                            _save(SettingsPatch(closeToTray: v), '设置已保存'),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.visibility_off_rounded,
                      title: '静默启动',
                      subtitle: '启动时隐藏到托盘',
                      trailing: Switch(
                        value: s.silentStart,
                        onChanged: (v) =>
                            _save(SettingsPatch(silentStart: v), '设置已保存'),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.power_settings_new_rounded,
                      title: '开机自动启动',
                      subtitle: '登录系统后自动运行',
                      trailing: Switch(
                        value: s.autoStart,
                        onChanged: _onAutoStartChanged,
                      ),
                    ),
                  ],
                ),
                _SettingsGroup(
                  title: '界面',
                  children: [
                    _SettingsRow(
                      icon: Icons.format_size_rounded,
                      title: '窗口缩放',
                      subtitle: '调整界面显示大小',
                      trailing: _ZoomStepper(
                        percent: (s.zoomLevel * 100).round(),
                        onDown: () => _zoomDelta(-10),
                        onUp: () => _zoomDelta(10),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.aspect_ratio_rounded,
                      title: '窗口自适应',
                      subtitle: '随窗口大小缩放，并记住位置',
                      trailing: Switch(
                        value: s.windowAdaptive,
                        onChanged: (v) =>
                            _save(SettingsPatch(windowAdaptive: v), '设置已保存'),
                      ),
                    ),
                    if (Platform.isWindows)
                      _SettingsRow(
                        icon: Icons.blur_on_rounded,
                        title: '亚克力背景',
                        subtitle: 'Windows 11 模糊材质',
                        trailing: Switch(
                          value: s.acrylicEnabled,
                          onChanged: _onAcrylicChanged,
                        ),
                      ),
                  ],
                ),
                _SettingsGroup(
                  title: '快捷键',
                  children: [
                    _SettingsRow(
                      icon: Icons.keyboard_rounded,
                      title: '全局快捷键',
                      subtitle: _hotkeyError.isEmpty
                          ? '唤醒窗口的快捷键'
                          : _hotkeyError,
                      subtitleColor: _hotkeyError.isEmpty
                          ? null
                          : CliphistColors.danger,
                      trailing: SizedBox(
                        width: 148,
                        child: _Field(
                          controller: _hotkeyCtrl,
                          onSubmit: _onHotkeySubmit,
                          hint: 'Ctrl+Shift+V',
                        ),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.touch_app_rounded,
                      title: '双击快捷键',
                      subtitle: s.doubleTapKey.isEmpty
                          ? '快速双击指定键唤醒窗口'
                          : helper
                          ? '已授权，双击 ${s.doubleTapKey} 唤醒'
                          : 'Linux 下首次使用需授权',
                      trailing: _Select(
                        value: s.doubleTapKey,
                        items: const [
                          ('', '禁用'),
                          ('Ctrl', 'Ctrl'),
                          ('Shift', 'Shift'),
                          ('Alt', 'Alt'),
                        ],
                        onChanged: (v) =>
                            _save(SettingsPatch(doubleTapKey: v), '双击快捷键已保存'),
                      ),
                    ),
                    _SettingsRow(
                      icon: Icons.sports_esports_rounded,
                      title: '游戏模式',
                      subtitle: '暂停双击唤醒，其它功能仍可用',
                      trailing: Switch(
                        value: s.gameMode,
                        onChanged: _onGameModeChanged,
                      ),
                    ),
                  ],
                ),
                _SettingsGroup(
                  title: '数据',
                  children: [
                    _SettingsRow(
                      icon: Icons.schedule_rounded,
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
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return CliphistHeaderBar(
      leading: CliphistHeaderButton(
        key: const ValueKey('settings-close'),
        icon: Icons.arrow_back_rounded,
        tooltip: '返回',
        label: '返回',
        alwaysLabeled: true,
        onTap: onClose,
      ),
      title: '偏好设置',
      subtitle: '自定义你的剪贴板工作流',
      actions: const [],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
            child: Text(
              title,
              style: const TextStyle(
                color: CliphistColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: CliphistColors.surface,
              borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
              border: Border.all(color: CliphistColors.borderSubtle),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      indent: 48,
                      color: CliphistColors.borderSubtle,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.subtitleColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CliphistColors.accentSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 15, color: CliphistColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CliphistColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: subtitleColor ?? CliphistColors.textMuted,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.noScaling),
            child: trailing,
          ),
        ],
      ),
    );
  }
}

class _ZoomStepper extends StatelessWidget {
  const _ZoomStepper({
    required this.percent,
    required this.onDown,
    required this.onUp,
  });

  final int percent;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ZoomBtn(icon: Icons.remove_rounded, onTap: onDown),
        SizedBox(
          width: 44,
          child: Text(
            '$percent%',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CliphistColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _ZoomBtn(icon: Icons.add_rounded, onTap: onUp),
      ],
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  const _ZoomBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CliphistColors.surfaceSubtle,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        side: const BorderSide(color: CliphistColors.borderSubtle),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(CliphistColors.radiusSm),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 15, color: CliphistColors.textSecondary),
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
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
    const radius = CliphistColors.radiusSm;
    return MenuAnchor(
      consumeOutsideTap: true,
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(16),
        shadowColor: const WidgetStatePropertyAll(Color(0x4017212B)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: const WidgetStatePropertyAll(CliphistColors.surface),
        padding: const WidgetStatePropertyAll(EdgeInsets.fromLTRB(6, 6, 6, 6)),
        minimumSize: const WidgetStatePropertyAll(Size(128, 0)),
        visualDensity: VisualDensity.compact,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CliphistColors.radiusLg),
            side: const BorderSide(color: CliphistColors.borderSubtle),
          ),
        ),
      ),
      builder: (context, controller, _) {
        final open = controller.isOpen;
        return Material(
          color: CliphistColors.surfaceSubtle,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(
              color: open ? CliphistColors.accent : CliphistColors.borderSubtle,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            onTap: _saving
                ? null
                : () =>
                      controller.isOpen ? controller.close() : controller.open(),
            child: SizedBox(
              width: 112,
              height: 32,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CliphistColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                    ),
                    Icon(
                      open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: CliphistColors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      menuChildren: [
        for (final item in widget.items)
          _SelectMenuItem(
            label: item.$2,
            selected: item.$1 == widget.value,
            onPressed: _saving ? null : () => _pick(item.$1),
          ),
      ],
    );
  }
}

class _SelectMenuItem extends StatelessWidget {
  const _SelectMenuItem({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MenuItemButton(
        onPressed: onPressed,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (selected) return CliphistColors.accentSoft;
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return CliphistColors.hover;
            }
            return Colors.transparent;
          }),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(116, 36)),
          visualDensity: VisualDensity.compact,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        child: SizedBox(
          width: 132,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? CliphistColors.accent
                        : CliphistColors.textPrimary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    height: 1.25,
                  ),
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: CliphistColors.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  String _subtitle(AppUpdateState update, String version) {
    if (update.phase == UpdatePhase.downloading) {
      return '正在下载 ${(update.downloadProgress * 100).round()}%';
    }
    if (update.phase == UpdatePhase.applying) {
      return Platform.isWindows ? '正在启动安装程序…' : '正在打开安装包…';
    }
    if (update.hasUpdate) return '发现新版本 v${update.latestVersion}';
    if (update.phase == UpdatePhase.failed) {
      final raw = update.errorMessage;
      if (raw.contains('403')) return '检查更新失败（GitHub 限制访问）';
      return '检查更新失败';
    }
    return '剪贴板历史管理器 · $version';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateStateProvider);
    final checking = update.phase == UpdatePhase.checking;
    final downloading = update.phase == UpdatePhase.downloading;
    final applying = update.phase == UpdatePhase.applying;
    final busy = checking || downloading || applying;
    final version = update.currentVersion.isEmpty
        ? '…'
        : 'v${update.currentVersion}';
    final percent = (update.downloadProgress * 100).round();
    final actionLabel = downloading
        ? '$percent%'
        : applying
        ? '安装中'
        : update.hasUpdate
        ? (update.canInstallInApp ? '安装' : '下载')
        : '检查更新';

    return _SettingsGroup(
      title: '关于',
      children: [
        _SettingsRow(
          icon: Icons.layers_rounded,
          title: 'My ClipHist',
          subtitle: _subtitle(update, version),
          subtitleColor: update.hasUpdate
              ? CliphistColors.accent
              : update.phase == UpdatePhase.failed
              ? CliphistColors.danger
              : null,
          trailing: FilledButton.tonal(
            onPressed: busy
                ? null
                : update.hasUpdate
                ? ClipHistController.instance.downloadAndInstallUpdate
                : ClipHistController.instance.checkForUpdates,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    actionLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                    strutStyle: const StrutStyle(
                      fontSize: 12,
                      height: 1.2,
                      leading: 0,
                      forceStrutHeight: true,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
