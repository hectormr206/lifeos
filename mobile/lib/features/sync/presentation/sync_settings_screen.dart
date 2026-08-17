import 'package:flutter/material.dart';

import '../domain/sync_connectivity.dart';
import '../domain/sync_disclosure.dart';

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
    required this.onEnable,
    required this.onDisable,
    required this.onSyncNow,
    required this.onOpenConflicts,
  });

  final SyncConnectivity connectivity;

  /// This device's name inside the user's own device set. Never leaves the
  /// device — the relay is never told it.
  final String deviceNickname;

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
          _StatusTile(connectivity: connectivity, scheme: scheme),
          const Divider(),

          SwitchListTile(
            value: _enabled,
            onChanged: (want) => want ? onEnable() : onDisable(),
            title: const Text('Sincronizar entre mis dispositivos'),
            subtitle: const Text(
              'Tus dispositivos comparten la misma información. Todo viaja '
              'cifrado y el servidor no puede leerlo.',
            ),
          ),

          if (_enabled) ...[
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: const Text('Este dispositivo'),
              subtitle: Text(deviceNickname),
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Sincronizar ahora'),
              // Manual sync runs on cellular too: the user asked. Said here so
              // nobody is surprised by the data it may use.
              subtitle: const Text(
                'Funciona también con datos móviles. La sincronización '
                'automática espera a que haya Wi-Fi.',
              ),
              onTap: onSyncNow,
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
