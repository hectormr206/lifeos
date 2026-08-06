/// Owns the dictation shortcut: loads it, registers it, lets the user change
/// it, and toggles a take when it fires.
///
/// The migration this completes: the shortcut used to be a desktop-environment
/// keybinding pointing at `axi/scripts/axi-toggle`, configured by hand on one
/// laptop. Now it ships with the app, on every desktop install, and is
/// changeable from Settings — "todo desde la app".
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../domain/dictation_hotkey.dart';
import '../domain/dictation_status.dart';
import '../domain/global_hotkey_binder.dart';
import 'dictate_controller.dart';
import 'dictation_providers.dart';

/// Where the chosen shortcut is stored between launches.
abstract class DictationHotkeyPreferences {
  Future<String?> load();
  Future<void> save(String value);
}

class SharedPrefsDictationHotkeyPreferences
    implements DictationHotkeyPreferences {
  static const String _key = 'dictation.hotkey';

  @override
  Future<String?> load() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> save(String value) async =>
      (await SharedPreferences.getInstance()).setString(_key, value);
}

/// The shortcut currently in effect, plus why it might not be.
class DictationHotkeyState {
  const DictationHotkeyState({
    this.hotkey = DictationHotkey.defaultHotkey,
    this.error,
  });

  /// The shortcut the app believes is registered. On a failed change this is
  /// the OLD one — the one that still works.
  final DictationHotkey hotkey;

  /// Why the shortcut is not currently registered, or null when it is. On
  /// Linux the usual cause is a missing `keybinder-3.0`; the other is another
  /// application already owning the combination.
  final String? error;

  DictationHotkeyState copyWith({
    DictationHotkey? hotkey,
    String? error,
    bool clearError = false,
  }) =>
      DictationHotkeyState(
        hotkey: hotkey ?? this.hotkey,
        error: clearError ? null : (error ?? this.error),
      );
}

class DictationHotkeyNotifier extends Notifier<DictationHotkeyState> {
  Future<void>? _startup;

  /// The binder that currently holds the combination, captured when this
  /// notifier is built. Held as a field for the same reason
  /// [DictateController] holds its recorder: `onDispose` runs when the
  /// container is already tearing down, and `ref` may no longer be read there.
  GlobalHotkeyBinder? _boundBinder;

  /// Lets tests (and the app's startup) await the initial load + registration
  /// deterministically instead of pumping until it happens to be done.
  Future<void> get ready => _startup ?? Future<void>.value();

  @override
  DictationHotkeyState build() {
    _startup = _loadAndBind();
    final binder = ref.read(globalHotkeyBinderProvider);
    ref.onDispose(() {
      // Hand the combination back to the OS. Leaving it held would keep the
      // key captured system-wide after LifeOS is gone.
      if (_boundBinder != null) unawaited(binder.unbind());
    });
    return const DictationHotkeyState();
  }

  Future<void> _loadAndBind() async {
    if (!supportsGlobalHotkeys(ref.read(hostOperatingSystemProvider))) return;

    String? stored;
    try {
      stored = await ref.read(dictationHotkeyPreferencesProvider).load();
    } catch (_) {
      // No platform channel (widget test, first launch): the default applies.
    }
    // A corrupt or unsafe stored value must never leave the user with NO
    // shortcut — fall back to the documented default rather than to nothing.
    final hotkey = DictationHotkey.tryParse(stored) ?? DictationHotkey.defaultHotkey;
    state = state.copyWith(hotkey: hotkey);
    await _register(hotkey);
  }

  /// Change the shortcut. Registers first and only then persists: a preference
  /// saved for a combination the OS refused would come back every launch and
  /// fail again, silently.
  Future<void> setHotkey(DictationHotkey hotkey) async {
    final previous = state.hotkey;
    if (!await _register(hotkey)) {
      // Put the working shortcut back. Refusing the new one AND dropping the
      // old one would leave dictation unreachable with nothing to explain it.
      await _register(previous);
      state = state.copyWith(hotkey: previous);
      return;
    }
    state = state.copyWith(hotkey: hotkey, clearError: true);
    try {
      await ref.read(dictationHotkeyPreferencesProvider).save(hotkey.toStorage());
    } catch (_) {
      // Best-effort persistence; the shortcut is already live this session.
    }
  }

  Future<bool> _register(DictationHotkey hotkey) async {
    try {
      final binder = ref.read(globalHotkeyBinderProvider);
      await binder.bind(hotkey, _toggleDictation);
      _boundBinder = binder;
      state = state.copyWith(clearError: true);
      return true;
    } on GlobalHotkeyUnavailableException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    } catch (e) {
      state = state.copyWith(error: 'No se pudo registrar el atajo: $e');
      return false;
    }
  }

  /// One press starts a take, the next stops it — the same semantics
  /// `axi.daemon.toggle()` has today, so the key does not change meaning.
  void _toggleDictation() {
    final controller = ref.read(dictateControllerProvider.notifier);
    if (ref.read(dictateControllerProvider) is DictationRecording) {
      unawaited(controller.stop());
    } else {
      unawaited(controller.start());
    }
  }
}

final dictationHotkeyProvider =
    NotifierProvider<DictationHotkeyNotifier, DictationHotkeyState>(
        DictationHotkeyNotifier.new);
