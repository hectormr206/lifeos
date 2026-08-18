// Two devices and the link between them, at a glance.
//
// Asked for directly: "necesitamos tener algo visual para que el usuario vea
// que ambos dispositivos están sincronizados". A line of text did not do it —
// the pass reported into a SnackBar that vanished, and "sincronización activa"
// only ever meant the switch was on, never that anything had crossed.
//
// The whole widget is built around ONE refusal: it must not look connected
// unless a real exchange actually completed. Three separate states could each
// have been painted green by accident, and each is a lie of a different kind:
//
//   * no peer at all — the switch is on and nothing is on the other end;
//   * a peer we have heard of but never exchanged with — the state right after
//     joining, where the data has NOT crossed yet;
//   * a peer and a FAILED pass — the most dangerous, because everything looks
//     configured.
import 'package:flutter/material.dart';

import '../data/sync_status_store.dart';

class SyncPairIndicator extends StatelessWidget {
  const SyncPairIndicator({
    super.key,
    required this.thisDevice,
    required this.peer,
    required this.status,
    this.pairingCode,
    this.pairingProblem,
    this.now,
  });

  /// Short id of this install.
  final String thisDevice;

  /// Short id of the other device, or null when none is known yet.
  final String? peer;

  /// The last recorded pass, or null when none has ever completed.
  final SyncStatus? status;

  /// Short fingerprint of the mailbox, which is derived from the RECOVERY
  /// PHRASE alone. Two devices sharing a phrase show the same code; two devices
  /// that each ran their own ceremony show different ones.
  ///
  /// This is the value that was missing while two healthy installs sat on
  /// different phrases, each reporting "Sin pareja" with nothing to compare.
  /// The relay held three mailboxes from three ceremonies and neither device
  /// could tell the user that.
  final String? pairingCode;

  /// Why [pairingCode] is missing, when it is.
  ///
  /// Rendering nothing was the original behaviour and it taught the user
  /// nothing: a device still computing the code, one that failed to, and one
  /// that never paired all looked exactly alike.
  final String? pairingProblem;

  /// Injectable clock, so the "hace 2 h" line is testable.
  final DateTime? now;

  /// The ONLY condition under which this may look connected.
  bool get _inSync => peer != null && status != null && status!.ok;

  bool get _failing => peer != null && status != null && !status!.ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final linkColour = _inSync
        ? scheme.primary
        : _failing
            ? scheme.error
            : scheme.outline;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Device(
                icon: Icons.phone_iphone,
                label: thisDevice,
                caption: 'Este',
                colour: scheme.primary,
              ),
              Expanded(
                child: _Link(colour: linkColour, connected: _inSync),
              ),
              _Device(
                icon: peer == null ? Icons.help_outline : Icons.devices_other,
                label: peer ?? '—',
                caption: peer == null ? 'Sin pareja' : 'El otro',
                colour: peer == null ? scheme.outline : scheme.primary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (peer == null && pairingCode == null && pairingProblem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                pairingProblem!,
                style: text.bodySmall?.copyWith(color: scheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          if (peer == null && pairingCode != null) ...[
            const SizedBox(height: 8),
            Text(
              'Código de emparejamiento: $pairingCode',
              style: text.labelLarge,
              textAlign: TextAlign.center,
            ),
            Text(
              'Los dos dispositivos deben mostrar el mismo. Si no coincide, '
              'están usando frases distintas y nunca se van a encontrar.',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _inSync
                    ? Icons.check_circle
                    : _failing
                        ? Icons.error_outline
                        : Icons.schedule,
                size: 18,
                color: linkColour,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _caption(),
                  style: text.bodyMedium?.copyWith(color: linkColour),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _caption() {
    if (peer == null) {
      return 'Todavía no hay otro dispositivo. Activa la sincronización en el '
          'segundo con la misma frase.';
    }
    if (status == null) {
      return 'Conocemos el otro dispositivo, pero todavía no se ha completado '
          'una sincronización.';
    }
    // On failure the REASON is shown, not a tidy summary: the user needs to
    // know whether to retry or to look at the network.
    if (!status!.ok) {
      return status!.message ?? 'La última sincronización falló.';
    }
    // Always with the time. A bare green tick reads as "just now" even when the
    // last pass was days ago, which is precisely how someone ends up trusting a
    // device that has been offline all week.
    return 'Sincronizados · ${describeSyncStatus(status, now: now)}';
  }
}

class _Device extends StatelessWidget {
  const _Device({
    required this.icon,
    required this.label,
    required this.caption,
    required this.colour,
  });

  final IconData icon;
  final String label;
  final String caption;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Icon(icon, size: 34, color: colour),
        const SizedBox(height: 4),
        Text(caption, style: text.labelSmall),
        Text(label, style: text.bodySmall?.copyWith(color: colour)),
      ],
    );
  }
}

/// The line between the two devices. Dashed and grey until a real exchange has
/// happened, solid once it has.
class _Link extends StatelessWidget {
  const _Link({required this.colour, required this.connected});

  final Color colour;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          Expanded(child: Divider(color: colour, thickness: connected ? 2 : 1)),
          Icon(
            connected ? Icons.sync_alt : Icons.more_horiz,
            size: 18,
            color: colour,
          ),
          Expanded(child: Divider(color: colour, thickness: connected ? 2 : 1)),
        ],
      ),
    );
  }
}
