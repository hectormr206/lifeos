import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workmanager/workmanager.dart';

import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/sync/keys.dart';
import 'package:lifeos/core/sync/stamping.dart';

import '../data/graph_sync_engine.dart';
import '../data/relay_reachability.dart';
import '../data/sync_pass.dart';
import '../data/workmanager_sync_work.dart';
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

/// Revisions that lost a merge, read from the database the engine writes to.
///
/// Was `const []` while the engine was unwired, which rendered as "no hay
/// conflictos" on a device that had never been able to have one — a screen
/// that could only ever say everything was fine.
final syncConflictsProvider = FutureProvider<List<SyncConflict>>((ref) async {
  final db = await ref.watch(graphDatabaseHandleProvider.future);
  final rows = await GraphSyncEngine(db).conflicts();
  return [
    for (final r in rows)
      SyncConflict(
        uuid: r['uuid']! as String,
        losingLamport: (r['losing_lamport'] as int?) ?? 0,
        losingOrigin: r['losing_origin'] as String?,
        // The stored payload is the whole losing row as JSON; the screen shows
        // its label, which is the only part a person can recognise.
        losingLabel: _labelOf(r['losing_payload'] as String?),
        resolvedAt: DateTime.fromMillisecondsSinceEpoch(
          (((r['resolved_at'] as num?) ?? 0) * 1000).round(),
        ),
      ),
  ];
});

/// Device uuid -> nickname, for the conflict list. Never leaves the device.
///
/// Only this device is named for now: a nickname for the OTHER device would
/// have to travel, and nothing carries it yet. Showing a shortened uuid is
/// honest; inventing "Mi otro dispositivo" for an id we cannot resolve is not.
final deviceNicknamesProvider = FutureProvider<Map<String, String>>((ref) async {
  final db = await ref.watch(graphDatabaseHandleProvider.future);
  return {await localOrigin(db): 'Este dispositivo'};
});

/// This device's short name, derived from its own origin so two devices never
/// show the same label.
final deviceNicknameProvider = FutureProvider<String>((ref) async {
  final db = await ref.watch(graphDatabaseHandleProvider.future);
  final origin = await localOrigin(db);
  return 'Este dispositivo (${origin.substring(0, 6)})';
});

/// The human-readable label inside a stored losing revision.
///
/// Falls back to the raw text rather than an empty string: a conflict entry
/// with no label at all is one the user cannot act on, and silently dropping it
/// would hide an edit that was already lost once.
String _labelOf(String? payloadJson) {
  if (payloadJson == null || payloadJson.isEmpty) return '(sin título)';
  try {
    final decoded = jsonDecode(payloadJson);
    if (decoded is Map && decoded['label'] is String) {
      return decoded['label'] as String;
    }
  } catch (_) {
    // Not JSON any more (an older row, a truncated write): show what we have.
  }
  return payloadJson;
}

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
      deviceNickname:
          ref.watch(deviceNicknameProvider).value ?? 'Este dispositivo',
      onEnable: () => _startEnabling(context, ref),
      onDisable: () async {
        await ref.read(syncEnablementProvider).disable();
        // Cancelled too: leaving a periodic task running after the user turned
        // sync off would keep waking the device for work it must not do.
        await WorkmanagerSyncScheduler(
          workmanager: Workmanager(),
          reportError: (_, _) {},
        ).cancel();
        ref.invalidate(syncEnabledProvider);
      },
      onSyncNow: () => _syncNow(context, ref),
      onOpenConflicts: () => context.push('/settings/sync/conflicts'),
    );
  }

  /// One real pass, on the user's explicit tap.
  ///
  /// Manual runs ignore the Wi-Fi rule on purpose — the user asked, and the
  /// screen says so. The RESULT is always shown, including failure: a tap that
  /// silently does nothing is how this button spent its first day.
  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final entropy = await ref.read(syncKeyStoreProvider).readEntropy();
    if (entropy == null) return;

    final db = await ref.read(graphDatabaseHandleProvider.future);
    final report = await SyncPass(
      db: db,
      keys: await deriveSyncKeys(entropy),
      relayBaseUrl: ref.read(relayBaseUrlProvider),
    ).run();

    ref.invalidate(syncConflictsProvider);
    messenger.showSnackBar(
      SnackBar(content: Text(describeSyncPass(report))),
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
            await _announce(ref);
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
            await _announce(ref);
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }
}

/// Tell the mailbox this device exists.
///
/// Without it two devices that have never spoken would each sit waiting for the
/// other to go first: a pass only sends to a peer it has HEARD from, and
/// neither would ever be heard. Best-effort — enabling sync must not fail
/// because the relay happened to be down.
Future<void> _announce(WidgetRef ref) async {
  // Automatic passes are registered HERE, at the moment sync is turned on, and
  // cancelled when it is turned off. Registering at app start instead would
  // schedule work for every user who never enabled the feature.
  await WorkmanagerSyncScheduler(
    workmanager: Workmanager(),
    reportError: (_, _) {},
  ).schedule();

  try {
    final entropy = await ref.read(syncKeyStoreProvider).readEntropy();
    if (entropy == null) return;
    await SyncPass(
      db: await ref.read(graphDatabaseHandleProvider.future),
      keys: await deriveSyncKeys(entropy),
      relayBaseUrl: ref.read(relayBaseUrlProvider),
    ).announce();
  } catch (_) {
    // Swallowed HERE and nowhere else: the next pass announces again, and the
    // settings screen reports the relay as unreachable on its own.
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
