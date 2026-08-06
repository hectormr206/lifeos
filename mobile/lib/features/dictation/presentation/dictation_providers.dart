import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dictation_channel.dart';
import '../domain/global_hotkey_binder.dart';
import 'dictation_hotkey_notifier.dart';

/// Native channel for the Axi keyboard (IME) setup. Overridden in tests.
final dictationChannelProvider = Provider<DictationChannel>(
  (ref) => DictationChannel(),
);

/// Live status of the two setup steps: (enabled in system settings, currently
/// selected keyboard). Re-read by invalidating this provider — the screen does
/// so on resume, since both change in SYSTEM UI, not in the app.
final dictationImeStatusProvider =
    FutureProvider.autoDispose<({bool enabled, bool selected})>((ref) async {
  final channel = ref.watch(dictationChannelProvider);
  return (
    enabled: await channel.isImeEnabled(),
    selected: await channel.isImeSelected(),
  );
});

/// Registers the dictation shortcut with the OS. Faked in tests.
final globalHotkeyBinderProvider =
    Provider<GlobalHotkeyBinder>((ref) => HotkeyManagerBinder());

/// Persistence for the chosen shortcut. Faked in tests.
final dictationHotkeyPreferencesProvider = Provider<DictationHotkeyPreferences>(
    (ref) => SharedPrefsDictationHotkeyPreferences());
