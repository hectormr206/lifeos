// Owning the shortcut end to end: load it, register it, let the user change it.
//
// The behaviours that matter here are the ones a user would notice and could
// not diagnose on their own — a shortcut that silently does not fire, a change
// that does not stick, or a rejected change that leaves the OLD shortcut dead
// as well as the new one refused.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/dictation/domain/dictation_hotkey.dart';
import 'package:lifeos/features/dictation/domain/global_hotkey_binder.dart';
import 'package:lifeos/features/dictation/presentation/dictation_hotkey_notifier.dart';
import 'package:lifeos/features/dictation/presentation/dictation_providers.dart';

class _FakeBinder implements GlobalHotkeyBinder {
  DictationHotkey? bound;
  int bindCalls = 0;
  int unbindCalls = 0;
  Exception? failWith;
  void Function()? handler;

  @override
  Future<void> bind(DictationHotkey hotkey, void Function() onPressed) async {
    bindCalls++;
    if (failWith != null) throw failWith!;
    bound = hotkey;
    handler = onPressed;
  }

  @override
  Future<void> unbind() async {
    unbindCalls++;
    bound = null;
  }
}

class _FakePrefs implements DictationHotkeyPreferences {
  _FakePrefs([this._stored]);

  String? _stored;

  @override
  Future<String?> load() async => _stored;

  @override
  Future<void> save(String value) async => _stored = value;
}

ProviderContainer _container({
  required _FakeBinder binder,
  DictationHotkeyPreferences? prefs,
  String os = 'linux',
}) {
  final container = ProviderContainer(overrides: [
    hostOperatingSystemProvider.overrideWithValue(os),
    globalHotkeyBinderProvider.overrideWithValue(binder),
    dictationHotkeyPreferencesProvider.overrideWithValue(prefs ?? _FakePrefs()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a fresh install binds Super+Space without being asked', () async {
    // The shortcut the user already has in their fingers must work on first
    // launch, with no trip to Settings.
    final binder = _FakeBinder();
    final container = _container(binder: binder);

    await container.read(dictationHotkeyProvider.notifier).ready;

    expect(binder.bound, DictationHotkey.defaultHotkey);
    expect(container.read(dictationHotkeyProvider).hotkey,
        DictationHotkey.defaultHotkey);
  });

  test('a shortcut the user chose earlier is restored', () async {
    const chosen = DictationHotkey(
      modifiers: {HotkeyModifier.control, HotkeyModifier.alt},
      key: LogicalKeyboardKey.keyD,
    );
    final binder = _FakeBinder();
    final container = _container(
      binder: binder,
      prefs: _FakePrefs(chosen.toStorage()),
    );

    await container.read(dictationHotkeyProvider.notifier).ready;

    expect(binder.bound, chosen);
  });

  test('a corrupted preference falls back to the default, still bound',
      () async {
    // Never end up with NO shortcut because a stored string went bad.
    final binder = _FakeBinder();
    final container =
        _container(binder: binder, prefs: _FakePrefs('garbage'));

    await container.read(dictationHotkeyProvider.notifier).ready;

    expect(binder.bound, DictationHotkey.defaultHotkey);
  });

  test('changing the shortcut registers it AND persists it', () async {
    final binder = _FakeBinder();
    final prefs = _FakePrefs();
    final container = _container(binder: binder, prefs: prefs);
    await container.read(dictationHotkeyProvider.notifier).ready;

    const next = DictationHotkey(
      modifiers: {HotkeyModifier.meta},
      key: LogicalKeyboardKey.keyJ,
    );
    await container.read(dictationHotkeyProvider.notifier).setHotkey(next);

    expect(binder.bound, next);
    expect(await prefs.load(), next.toStorage());
  });

  test('a rejected shortcut leaves the WORKING one in place', () async {
    // The trap: refusing the new binding but having already dropped the old
    // one would leave the user with no shortcut at all and no error to explain
    // it. Whatever else happens, dictation must stay reachable.
    final binder = _FakeBinder();
    final container = _container(binder: binder);
    await container.read(dictationHotkeyProvider.notifier).ready;

    binder.failWith = const GlobalHotkeyUnavailableException('ya está en uso');
    const taken = DictationHotkey(
      modifiers: {HotkeyModifier.control},
      key: LogicalKeyboardKey.keyC,
    );
    await container.read(dictationHotkeyProvider.notifier).setHotkey(taken);

    final state = container.read(dictationHotkeyProvider);
    expect(state.hotkey, DictationHotkey.defaultHotkey,
        reason: 'the stored shortcut must not move when binding failed');
    expect(state.error, contains('ya está en uso'));
  });

  test('a failure to bind at startup is REPORTED, not swallowed', () async {
    // On Linux this is the missing keybinder-3.0 case. A shortcut that never
    // fires with no message is indistinguishable from a broken keyboard.
    final binder = _FakeBinder()
      ..failWith = const GlobalHotkeyUnavailableException('falta keybinder');
    final container = _container(binder: binder);

    await container.read(dictationHotkeyProvider.notifier).ready;

    expect(container.read(dictationHotkeyProvider).error,
        contains('falta keybinder'));
  });

  test('Android never registers anything', () async {
    // No global-shortcut concept there; the assistant gesture is the phone's
    // equivalent and lives elsewhere entirely.
    final binder = _FakeBinder();
    final container = _container(binder: binder, os: 'android');

    await container.read(dictationHotkeyProvider.notifier).ready;

    expect(binder.bindCalls, 0);
    expect(container.read(dictationHotkeyProvider).error, isNull,
        reason: 'not supported is not an error — it is simply absent');
  });
}
