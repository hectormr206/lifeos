import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_tokens.dart';
import '../domain/sync_conflict.dart';

/// "Ajustes → Sincronizar → Historial de conflictos".
///
/// This screen is what makes the merge rules honest. The engine keeps exactly
/// one version of each record, and the other one lands here rather than being
/// destroyed — including the case that matters most: an edit that lost to a
/// delete despite having the higher clock.
///
/// Deliberately plain. A conflict list is read at a bad moment, by someone who
/// noticed something missing; it should answer "what was it, when, and from
/// which device" without ceremony.
class ConflictHistoryScreen extends StatelessWidget {
  const ConflictHistoryScreen({
    super.key,
    required this.conflicts,
    required this.nicknamesByUuid,
    required this.onRestore,
  });

  final List<SyncConflict> conflicts;

  /// Device uuid -> the name the user gave it. Never leaves the device; the
  /// relay is never told any of these.
  final Map<String, String> nicknamesByUuid;

  /// Put a losing version back. It becomes a NEW local write with a fresh
  /// clock — not a rewrite of history — so it wins cleanly and syncs onward
  /// like any other change.
  final void Function(SyncConflict conflict) onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Historial de conflictos')),
      body: conflicts.isEmpty
          ? const _Empty()
          : PageBody(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.lg),
                  child: Text(
                    'Cuando dos dispositivos cambian lo mismo, se conserva '
                    'una versión y la otra queda aquí. Nunca se borra sola.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                GroupedList(
                  children: [
                    for (final c in conflicts)
                      GroupedRow(
                        title: c.losingLabel,
                        subtitle: 'Desde ${c.deviceLabel(nicknamesByUuid)} · '
                            '${_when(c.resolvedAt)}',
                        trailing: TextButton(
                          onPressed: () => onRestore(c),
                          child: const Text('Restaurar'),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  static String _when(DateTime at) =>
      '${at.day.toString().padLeft(2, '0')}/'
      '${at.month.toString().padLeft(2, '0')}/${at.year}';
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(Space.xxxl),
      child: EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Sin conflictos',
        // Says what the emptiness MEANS. "Nada aquí" would leave the user
        // unsure whether the feature works or simply has nothing to show.
        message: 'Tus dispositivos no han cambiado lo mismo al mismo tiempo. Si '
            'llega a pasar, la versión que no quede aparecerá aquí.',
      ),
    );
  }
}
