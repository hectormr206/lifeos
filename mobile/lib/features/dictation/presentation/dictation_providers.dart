import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dictation_channel.dart';

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
