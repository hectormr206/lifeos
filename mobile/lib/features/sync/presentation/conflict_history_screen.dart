import 'package:flutter/material.dart';

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
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Historial de conflictos')),
      body: conflicts.isEmpty
          ? _Empty(text: text)
          : ListView.separated(
              itemCount: conflicts.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Cuando dos dispositivos cambian lo mismo, se conserva '
                      'una versión y la otra queda aquí. Nunca se borra sola.',
                      style: text.bodyMedium,
                    ),
                  );
                }
                final c = conflicts[index - 1];
                return ListTile(
                  title: Text(c.losingLabel),
                  subtitle: Text(
                    'Desde ${c.deviceLabel(nicknamesByUuid)} · '
                    '${_when(c.resolvedAt)}',
                  ),
                  trailing: TextButton(
                    onPressed: () => onRestore(c),
                    child: const Text('Restaurar'),
                  ),
                );
              },
            ),
    );
  }

  static String _when(DateTime at) =>
      '${at.day.toString().padLeft(2, '0')}/'
      '${at.month.toString().padLeft(2, '0')}/${at.year}';
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 48),
            const SizedBox(height: 16),
            Text(
              'Sin conflictos',
              style: text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              // Says what the emptiness MEANS. "Nada aquí" would leave the user
              // unsure whether the feature works or simply has nothing to show.
              'Tus dispositivos no han cambiado lo mismo al mismo tiempo. Si '
              'llega a pasar, la versión que no quede aparecerá aquí.',
              style: text.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
