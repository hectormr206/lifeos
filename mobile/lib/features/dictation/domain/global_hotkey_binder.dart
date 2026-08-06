/// Registers the dictation shortcut with the operating system.
///
/// Split from [DictationHotkey] because registration is the only part that
/// touches a platform channel, and the rest of the feature — the value, the
/// validation, the preference, the settings UI — must be testable without one.
///
/// ON LINUX this goes through `keybinder-3.0`, a native library the Flutter
/// plugin links against. Like `parecord` and `ffmpeg` for the recorder, it is
/// not something the app can install for the user, so `install-linux.sh` probes
/// for it and reports it by name. If it is missing, binding FAILS LOUDLY: a
/// shortcut that silently never fires is indistinguishable from a broken
/// keyboard, and the user would have no way to tell which.
library;

import 'package:hotkey_manager/hotkey_manager.dart';

import 'dictation_hotkey.dart';

/// Thrown when the shortcut cannot be registered with the OS.
class GlobalHotkeyUnavailableException implements Exception {
  const GlobalHotkeyUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Binds one shortcut at a time to one callback.
abstract class GlobalHotkeyBinder {
  /// Register [hotkey], replacing whatever was registered before. The callback
  /// fires on every press, from anywhere in the OS.
  Future<void> bind(DictationHotkey hotkey, void Function() onPressed);

  /// Release the shortcut back to the system.
  Future<void> unbind();
}

/// The real binder, on top of `hotkey_manager`.
class HotkeyManagerBinder implements GlobalHotkeyBinder {
  HotkeyManagerBinder({HotKeyManager? manager})
      : _manager = manager ?? hotKeyManager;

  final HotKeyManager _manager;

  static const Map<HotkeyModifier, HotKeyModifier> _modifierMap = {
    HotkeyModifier.meta: HotKeyModifier.meta,
    HotkeyModifier.control: HotKeyModifier.control,
    HotkeyModifier.alt: HotKeyModifier.alt,
    HotkeyModifier.shift: HotKeyModifier.shift,
  };

  @override
  Future<void> bind(DictationHotkey hotkey, void Function() onPressed) async {
    if (!hotkey.isValid) {
      // Refuse before touching the OS: a modifier-less shortcut would capture
      // that key for every other application on the machine.
      throw const GlobalHotkeyUnavailableException(
        'Ese atajo no se puede usar: necesita al menos una tecla '
        'modificadora (Ctrl, Alt, Shift o Super).',
      );
    }
    await unbind();
    try {
      await _manager.register(
        HotKey(
          identifier: 'lifeos.dictation.toggle',
          key: hotkey.key,
          modifiers: [
            for (final modifier in hotkey.modifiers) _modifierMap[modifier]!,
          ],
          scope: HotKeyScope.system,
        ),
        keyDownHandler: (_) => onPressed(),
      );
    } catch (e) {
      // Two realistic causes, and the user can act on both: the native
      // keybinder library is absent, or another application already owns the
      // combination. Neither may be swallowed.
      throw GlobalHotkeyUnavailableException(
        'No se pudo registrar ${hotkey.label} en el sistema. Puede que otra '
        'aplicación ya lo esté usando, o que falte la librería keybinder-3.0. '
        'Detalle: $e',
      );
    }
  }

  @override
  Future<void> unbind() async {
    try {
      await _manager.unregisterAll();
    } catch (_) {
      // Releasing a shortcut that was never held is not a failure worth
      // surfacing — unlike acquiring one, nothing depends on it having worked.
    }
  }
}
