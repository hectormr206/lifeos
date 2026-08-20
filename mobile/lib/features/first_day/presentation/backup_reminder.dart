import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graph/graph_providers.dart';
import '../data/backup_nag_store.dart';
import '../domain/backup_nag.dart';

/// El aviso que hace que el respaldo exista de verdad.
///
/// LifeOS ya tenía respaldo cifrado, respaldo automático y exportación, y
/// ninguno protegía a nadie: los tres hay que encenderlos antes, y nadie
/// enciende copias antes de necesitarlas. Esto es lo único que faltaba —
/// preguntarlo cuando ya hay algo que perder, y volver a preguntarlo mientras
/// la respuesta siga siendo "todavía no".
final backupNagStoreProvider = Provider<BackupNagStore>((ref) => BackupNagStore());

/// Cuántas cosas hay guardadas, sin contarlas todas: en cuanto llega al umbral
/// deja de importar el número exacto, y pedir la lista entera en cada arranque
/// para responder "¿hay más de veinte?" sería caro por nada.
final storedEntriesProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  final facts = await store.listNodesByKind(
    'fact',
    limit: kEntriesWorthProtecting + 1,
  );
  return facts.length;
});

final shouldAskForBackupProvider = FutureProvider<bool>((ref) async {
  final nag = ref.watch(backupNagStoreProvider);
  final entries = await ref.watch(storedEntriesProvider.future);
  return shouldAskForBackup(
    BackupState(
      hasBackup: await nag.hasBackup(),
      postponedAt: await nag.postponedAt(),
      askedTimes: await nag.askedTimes(),
      entriesStored: entries,
    ),
    now: DateTime.now(),
  );
});

/// La tarjeta. Aparece sola, dice qué se pierde y ofrece la salida en un toque.
class BackupReminderBanner extends ConsumerWidget {
  const BackupReminderBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ask = ref.watch(shouldAskForBackupProvider);
    // Mientras no se sepa, no se enseña nada: un aviso que parpadea en cada
    // arranque enseña a ignorarlo.
    if (ask.value != true) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined, size: 18),
                const SizedBox(width: 10),
                Text('Si pierdes este teléfono', style: text.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Todo lo que me has contado vive aquí dentro, y sólo aquí. Una '
              'copia tarda un minuto en hacerse y se guarda cifrada donde tú '
              'decidas: sólo tú puedes abrirla.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: () async {
                    await ref.read(backupNagStoreProvider).markBackedUp();
                    ref.invalidate(shouldAskForBackupProvider);
                    if (context.mounted) context.push('/settings/backups');
                  },
                  child: const Text('Guardar mi copia'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    await ref
                        .read(backupNagStoreProvider)
                        .postpone(DateTime.now());
                    ref.invalidate(shouldAskForBackupProvider);
                  },
                  child: const Text('Luego'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
