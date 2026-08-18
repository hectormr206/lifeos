import 'package:flutter/material.dart';

import '../data/sync_status_store.dart';
import '../domain/sync_connectivity.dart';
import '../domain/sync_disclosure.dart';
import 'sync_pair_indicator.dart';

/// "Ajustes → Sincronizar dispositivos".
///
/// The screen is deliberately honest before it is inviting. A person deciding
/// whether to let their whole life travel through a server should read what
/// that server can see BEFORE the switch, not in a policy they will never open.
///
/// Every rule this screen obeys is pinned by tests in
/// `test/features/sync/sync_ux_test.dart`:
///
///   * the status line reflects RELAY reachability, never the VPN;
///   * turning sync off clears keys and touches nothing else;
///   * the residual-metadata list is shown verbatim, including the parts that
///     are uncomfortable.
///
/// This widget composes those decisions; it does not restate them. If the copy
/// here ever disagrees with `sync_disclosure.dart`, the disclosure wins — it is
/// the one with a test asserting it matches what the relay actually stores.
class SyncSettingsScreen extends StatelessWidget {
  const SyncSettingsScreen({
    super.key,
    required this.connectivity,
    required this.deviceNickname,
    required this.lastSyncLine,
    this.enablementKnown = true,
    required this.thisDeviceId,
    required this.peerDeviceId,
    required this.lastStatus,
    required this.onEnable,
    required this.onDisable,
    required this.onSyncNow,
    required this.onOpenConflicts,
  });

  final SyncConnectivity connectivity;

  /// This device's name inside the user's own device set. Never leaves the
  /// device — the relay is never told it.
  final String deviceNickname;

  /// What the LAST pass did, already formatted. Shown permanently because the
  /// SnackBar that used to carry this vanished in seconds, and the automatic
  /// pass has no screen at all — its outcome was known only to a process that
  /// then exited.
  final String lastSyncLine;

  /// False while the keystore read is still in flight.
  ///
  /// Kept separate from [connectivity] on purpose. Collapsing "we do not know
  /// yet" into "off" shows an ENABLED device an off switch; tapping it offers
  /// to create a new phrase, which mints a new key and orphans the data behind
  /// the old one. Unknown must look unknown.
  final bool enablementKnown;

  /// Short ids for the picture at the top. The indicator refuses to look
  /// connected without a peer AND a completed pass, so these are not cosmetic.
  final String thisDeviceId;
  final String? peerDeviceId;
  final SyncStatus? lastStatus;

  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onSyncNow;
  final VoidCallback onOpenConflicts;

  bool get _enabled => connectivity != SyncConnectivity.notEnabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizar dispositivos')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_enabled) ...[
            SyncPairIndicator(
              thisDevice: thisDeviceId,
              peer: peerDeviceId,
              status: lastStatus,
            ),
            // The primary action lives HERE, with the picture it acts on, and
            // not four rows below the switch where it used to be. Adding the
            // indicator above pushed that row off a phone screen entirely —
            // "no hay ningún botón de Sincronizar ahora" — so the widget meant
            // to make sync legible had hidden its only control.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: FilledButton.icon(
                onPressed: onSyncNow,
                icon: const Icon(Icons.sync),
                label: const Text('Sincronizar ahora'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Funciona también con datos móviles. La automática espera Wi-Fi.',
                style: text.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ],
          _StatusTile(connectivity: connectivity, scheme: scheme),
          const Divider(),

          SwitchListTile(
            value: _enabled,
            // Null while unknown: disables the tile, so the state cannot be
            // flipped from a value we have not actually read yet.
            onChanged: enablementKnown
                ? (want) => want ? onEnable() : onDisable()
                : null,
            title: const Text('Sincronizar entre mis dispositivos'),
            subtitle: Text(
              enablementKnown
                  ? 'Tus dispositivos comparten la misma información. Todo '
                      'viaja cifrado y el servidor no puede leerlo.'
                  : 'Comprobando…',
            ),
          ),

          if (_enabled) ...[
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: const Text('Este dispositivo'),
              subtitle: Text(deviceNickname),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Última sincronización'),
              subtitle: Text(lastSyncLine),
            ),
            ListTile(
              leading: const Icon(Icons.history_toggle_off),
              title: const Text('Historial de conflictos'),
              subtitle: const Text(
                'Cuando dos dispositivos cambian lo mismo, se guarda la '
                'versión que no quedó. Nunca se pierde.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenConflicts,
            ),
          ],

          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Qué puede ver el servidor', style: text.titleMedium),
          ),
          // Rendered from the SAME constants the test asserts against, not
          // retyped here. Retyped copy is copy that drifts.
          for (final o in kRelayCanSee)
            ListTile(
              dense: true,
              leading: const Icon(Icons.visibility_outlined, size: 20),
              title: Text(o.what),
              subtitle: Text(o.why),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Qué NO puede ver', style: text.titleMedium),
          ),
          for (final line in kRelayCannotSee)
            ListTile(
              dense: true,
              leading: Icon(Icons.visibility_off_outlined,
                  size: 20, color: scheme.primary),
              title: Text(line),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Text(kRelayRetention, style: text.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.connectivity, required this.scheme});

  final SyncConnectivity connectivity;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    // Only `unreachable` is coloured as a problem. Badging a deliberate choice
    // ("desactivada") or a normal wait ("esperando Wi-Fi") as an error teaches
    // people to ignore the badge that matters.
    final problem = connectivity.isProblem;

    return ListTile(
      leading: Icon(
        switch (connectivity) {
          SyncConnectivity.reachable => Icons.cloud_done_outlined,
          SyncConnectivity.notEnabled => Icons.cloud_off_outlined,
          SyncConnectivity.unreachable => Icons.cloud_off,
          SyncConnectivity.waitingForWifi => Icons.wifi_find_outlined,
        },
        color: problem ? scheme.error : scheme.primary,
      ),
      title: Text(
        connectivity.label,
        style: TextStyle(color: problem ? scheme.error : null),
      ),
    );
  }
}
