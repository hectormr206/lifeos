import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/relay_reachability.dart';
import '../data/sync_key_store.dart';
import '../domain/phrase_ceremony.dart';
import '../domain/sync_conflict.dart';
import '../domain/sync_connectivity.dart';
import '../domain/sync_enablement.dart';
import 'conflict_history_screen.dart';
import 'phrase_ceremony_screen.dart';
import 'phrase_restore_screen.dart';
import 'sync_settings_screen.dart';

/// Wiring only. The screens themselves take plain values and callbacks so they
/// can be widget-tested without Riverpod, a keystore or a network — the same
/// separation the rest of the feature uses, and the reason those tests run in
/// milliseconds and assert real behaviour instead of mocking a container.

final syncKeyStoreProvider = Provider<SyncKeyStore>((ref) => SecureSyncKeyStore());

final syncEnablementProvider = Provider<SyncEnablement>(
  (ref) => SyncEnablement(store: ref.watch(syncKeyStoreProvider)),
);

/// Whether sync is on, re-read from the keystore.
///
/// Derived from the presence of key material rather than a separate flag, so a
/// stored "enabled = true" can never disagree with whether we can actually
/// decrypt anything.
final syncEnabledProvider = FutureProvider<bool>(
  (ref) => ref.watch(syncEnablementProvider).isEnabled(),
);

/// Where the blind relay lives. Empty until one is configured, and an empty
/// value means "unreachable" rather than "assume it works" — see
/// `RelayReachability.check`.
///
/// Injected at build time the same way every other host in this app is
/// (`--dart-define`), so a debug build can point at a local relay without
/// editing source.
const String kRelayBaseUrl = String.fromEnvironment('SYNC_RELAY_URL');

final relayBaseUrlProvider = Provider<String>((ref) => kRelayBaseUrl);

/// Whether the relay ANSWERED. NOT the VPN — see `sync_connectivity.dart`.
///
/// A real probe, not an optimistic `true`: a phone can be on excellent Wi-Fi
/// with the relay down, and a captive portal reports itself as connected while
/// swallowing every request.
final relayReachableProvider = FutureProvider<bool>((ref) async {
  return RelayReachability(baseUrl: ref.watch(relayBaseUrlProvider)).check();
});

/// Conflicts awaiting the user's attention. Empty until the engine is wired.
final syncConflictsProvider = FutureProvider<List<SyncConflict>>(
  (ref) async => const [],
);

/// Device uuid -> nickname, for the conflict list. Never leaves the device.
final deviceNicknamesProvider = FutureProvider<Map<String, String>>(
  (ref) async => const {},
);

class SyncSettingsRoute extends ConsumerWidget {
  const SyncSettingsRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(syncEnabledProvider).value ?? false;
    final reachable = ref.watch(relayReachableProvider).value ?? false;

    return SyncSettingsScreen(
      connectivity: resolveSyncConnectivity(
        syncEnabled: enabled,
        relayReachable: reachable,
        // Wi-Fi state is only ever consulted for AUTOMATIC passes; the settings
        // screen shows the steady state, and a manual tap ignores it anyway.
        onUnmeteredNetwork: true,
      ),
      deviceNickname: 'Este dispositivo',
      onEnable: () => _startEnabling(context, ref),
      onDisable: () async {
        await ref.read(syncEnablementProvider).disable();
        ref.invalidate(syncEnabledProvider);
      },
      onSyncNow: () {},
      onOpenConflicts: () => context.push('/settings/sync/conflicts'),
    );
  }

  /// Enabling asks WHICH device this is before it does anything.
  ///
  /// The question is not a courtesy. Generating unconditionally — which is what
  /// this did until the second device was actually tried — gives every install
  /// its own key. Both then report "sincronización activa" and neither can read
  /// a single envelope the other wrote: no error, no failed request, just two
  /// devices quietly alone. Asking is what makes joining possible at all.
  void _startEnabling(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                '¿Es tu primer dispositivo con LifeOS, o ya tienes otro '
                'sincronizando?',
                style: TextStyle(fontSize: 16),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Es el primero'),
              subtitle: const Text(
                'Se crea una frase nueva de doce palabras y la anotas.',
              ),
              onTap: () {
                Navigator.of(sheet).pop();
                _startCeremony(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.devices_other_outlined),
              title: const Text('Ya tengo otro dispositivo'),
              subtitle: const Text(
                'Escribes la frase de ese dispositivo y los dos comparten la '
                'misma información.',
              ),
              onTap: () {
                Navigator.of(sheet).pop();
                _startRestore(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _startRestore(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhraseRestoreScreen(
          onCancel: () => Navigator.of(context).pop(),
          onRestore: (mnemonic) async {
            // `restore` re-validates the checksum and throws before touching
            // storage, so a phrase that somehow got here malformed cannot
            // half-enable the device.
            await ref.read(syncEnablementProvider).restore(mnemonic);
            ref.invalidate(syncEnabledProvider);
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  void _startCeremony(BuildContext context, WidgetRef ref) {
    final ceremony = PhraseCeremony.generate();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhraseCeremonyScreen(
          ceremony: ceremony,
          onCancel: () => Navigator.of(context).pop(),
          onConfirmed: (confirmed) async {
            // `enable` refuses an unconfirmed ceremony, so this cannot turn
            // sync on from a phrase the user never proved they wrote down.
            await ref.read(syncEnablementProvider).enable(confirmed);
            ref.invalidate(syncEnabledProvider);
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }
}

class ConflictHistoryRoute extends ConsumerWidget {
  const ConflictHistoryRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConflictHistoryScreen(
      conflicts: ref.watch(syncConflictsProvider).value ?? const [],
      nicknamesByUuid: ref.watch(deviceNicknamesProvider).value ?? const {},
      onRestore: (_) {},
    );
  }
}
