/// The Settings row that shows the dictation shortcut and lets the user change
/// it — the "todo desde la app" half of owning the hotkey.
///
/// ABSENT, not disabled, where global shortcuts do not exist (the phones). Same
/// product rule the tray and the update controls already follow: a control that
/// is shown is a control that works.
///
/// Capture rather than a dropdown: the user presses the combination they want.
/// A picker listing every key would be both enormous and worse — you cannot
/// tell whether a combination is comfortable without pressing it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../domain/dictation_hotkey.dart';
import 'dictation_hotkey_notifier.dart';

class DictationHotkeyTile extends ConsumerWidget {
  const DictationHotkeyTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!supportsGlobalHotkeys(ref.watch(hostOperatingSystemProvider))) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(dictationHotkeyProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.keyboard),
      title: const Text('Atajo para dictar'),
      subtitle: Text(
        state.error ??
            'Presiona ${state.hotkey.label} desde cualquier lado para empezar '
                'o detener el dictado.',
        style: state.error == null ? null : TextStyle(color: scheme.error),
      ),
      trailing: OutlinedButton(
        onPressed: () => _capture(context, ref),
        child: Text(state.hotkey.label),
      ),
    );
  }

  Future<void> _capture(BuildContext context, WidgetRef ref) async {
    final captured = await showDialog<DictationHotkey>(
      context: context,
      builder: (_) => const _HotkeyCaptureDialog(),
    );
    if (captured == null) return;
    await ref.read(dictationHotkeyProvider.notifier).setHotkey(captured);
  }
}

class _HotkeyCaptureDialog extends StatefulWidget {
  const _HotkeyCaptureDialog();

  @override
  State<_HotkeyCaptureDialog> createState() => _HotkeyCaptureDialogState();
}

class _HotkeyCaptureDialogState extends State<_HotkeyCaptureDialog> {
  DictationHotkey? _candidate;

  /// Rejects a combination BEFORE the user commits to it, with the reason. The
  /// notifier enforces the same rule, but finding out after pressing "Guardar"
  /// that a shortcut was never legal is a worse way to learn it.
  String? get _problem {
    final candidate = _candidate;
    if (candidate == null) return null;
    if (!candidate.isValid) {
      return 'Necesita al menos una tecla modificadora (Ctrl, Alt, Shift o '
          'Super) además de la tecla.';
    }
    return null;
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final modifiers = <HotkeyModifier>{
      if (_anyOf(pressed, LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight, LogicalKeyboardKey.control))
        HotkeyModifier.control,
      if (_anyOf(pressed, LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight, LogicalKeyboardKey.alt))
        HotkeyModifier.alt,
      if (_anyOf(pressed, LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight, LogicalKeyboardKey.shift))
        HotkeyModifier.shift,
      if (_anyOf(pressed, LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.metaRight, LogicalKeyboardKey.meta))
        HotkeyModifier.meta,
    };
    setState(() {
      _candidate =
          DictationHotkey(modifiers: modifiers, key: event.logicalKey);
    });
  }

  static bool _anyOf(Set<LogicalKeyboardKey> pressed, LogicalKeyboardKey a,
          LogicalKeyboardKey b, LogicalKeyboardKey c) =>
      pressed.contains(a) || pressed.contains(b) || pressed.contains(c);

  @override
  Widget build(BuildContext context) {
    final candidate = _candidate;
    final problem = _problem;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Nuevo atajo'),
      content: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Presiona la combinación que quieres usar.'),
            const SizedBox(height: 16),
            Text(
              candidate?.label ?? '—',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (problem != null) ...[
              const SizedBox(height: 8),
              Text(problem, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: candidate != null && problem == null
              ? () => Navigator.of(context).pop(candidate)
              : null,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
