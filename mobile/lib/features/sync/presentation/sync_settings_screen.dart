import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_tokens.dart';

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
    this.pairingCode,
    this.pairingProblem,
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

  /// Short fingerprint of the mailbox, for comparing two devices by eye.
  final String? pairingCode;

  /// Why [pairingCode] is missing, when it is.
  final String? pairingProblem;

  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onSyncNow;
  final VoidCallback onOpenConflicts;

  bool get _enabled => connectivity != SyncConnectivity.notEnabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final quiet = text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);

    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizar dispositivos')),
      body: PageBody(
        children: [
          if (_enabled) ...[
            SyncPairIndicator(
              thisDevice: thisDeviceId,
              peer: peerDeviceId,
              status: lastStatus,
              pairingCode: pairingCode,
              pairingProblem: pairingProblem,
            ),
            // The primary action lives HERE, with the picture it acts on, and
            // not four rows below the switch where it used to be. Adding the
            // indicator above pushed that row off a phone screen entirely —
            // "no hay ningún botón de Sincronizar ahora" — so the widget meant
            // to make sync legible had hidden its only control.
            FilledButton.icon(
              onPressed: onSyncNow,
              icon: const Icon(Icons.sync),
              label: const Text('Sincronizar ahora'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: Space.sm, bottom: Space.lg),
              child: Text(
                'Funciona también con datos móviles. La automática espera Wi-Fi.',
                style: quiet,
                textAlign: TextAlign.center,
              ),
            ),
          ],
          GroupedList(
            children: [
              _StatusTile(connectivity: connectivity, scheme: scheme),
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
            ],
          ),
          if (_enabled) ...[
            const SizedBox(height: Space.lg),
            GroupedList(
              children: [
                GroupedRow(
                  icon: Icons.devices_outlined,
                  title: 'Este dispositivo',
                  subtitle: deviceNickname,
                ),
                GroupedRow(
                  icon: Icons.schedule,
                  title: 'Última sincronización',
                  subtitle: lastSyncLine,
                ),
                GroupedRow(
                  icon: Icons.history_toggle_off,
                  title: 'Historial de conflictos',
                  subtitle: 'Cuando dos dispositivos cambian lo mismo, se guarda '
                      'la versión que no quedó. Nunca se pierde.',
                  subtitleMaxLines: null,
                  onTap: onOpenConflicts,
                ),
              ],
            ),
          ],
          const SectionHeader('Qué puede ver el servidor'),
          // Rendered from the SAME constants the test asserts against, not
          // retyped here. Retyped copy is copy that drifts.
          GroupedList(
            children: [
              for (final o in kRelayCanSee)
                ListTile(
                  leading: const Icon(Icons.visibility_outlined, size: 20),
                  title: Text(o.what),
                  subtitle: Text(o.why),
                ),
            ],
          ),
          const SectionHeader('Qué NO puede ver'),
          GroupedList(
            children: [
              for (final line in kRelayCannotSee)
                ListTile(
                  leading: Icon(Icons.visibility_off_outlined,
                      size: 20, color: scheme.primary),
                  title: Text(line),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: Space.lg),
            child: Text(kRelayRetention, style: quiet),
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
