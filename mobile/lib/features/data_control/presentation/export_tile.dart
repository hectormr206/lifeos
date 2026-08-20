// "Llévate tus datos" — the tile and what happens when it is tapped.
//
// It sits next to the backups because a person reads them as one subject
// ("dónde está mi información"), even though they do opposite jobs: a backup
// comes back INTO LifeOS, an export goes OUT of it and does not need us to be
// readable — or to exist.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../data/export_service.dart';

class ExportTile extends ConsumerWidget {
  const ExportTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.ios_share),
      title: const Text('Llévate tus datos'),
      subtitle: const Text(
        'Una copia legible de todo, para abrirla donde quieras — aunque un día '
        'no uses LifeOS.',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _choose(context, ref),
    );
  }

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final format = await showModalBottomSheet<ExportFormat>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Se exporta TODO lo que LifeOS sabe de ti: tus registros, tus '
                'personas, las relaciones entre ellos y lo que has borrado.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('Hoja de cálculo (CSV)'),
              subtitle: const Text(
                'Se abre en Excel, Numbers o Google Sheets. Lo más fácil de '
                'leer.',
              ),
              onTap: () => Navigator.of(context).pop(ExportFormat.csv),
            ),
            ListTile(
              leading: const Icon(Icons.data_object),
              title: const Text('Archivo completo (JSON)'),
              subtitle: const Text(
                'Todo, con las relaciones incluidas. Para llevarlo a otro '
                'programa.',
              ),
              onTap: () => Navigator.of(context).pop(ExportFormat.json),
            ),
          ],
        ),
      ),
    );
    if (format == null) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final store = await ref.read(localGraphStoreProvider.future);
      await ExportService(store).shareExport(format);
    } catch (error) {
      // Says what happened. An export that fails silently leaves someone
      // believing they have a copy of their life when they do not.
      messenger.showSnackBar(
        SnackBar(content: Text('No se pudo exportar: $error')),
      );
    }
  }
}
