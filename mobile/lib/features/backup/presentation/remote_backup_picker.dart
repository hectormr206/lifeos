import 'package:flutter/material.dart';

import '../domain/backup_host_diagnosis.dart';

/// Lets the user pick WHICH archive to restore.
///
/// Newest first, because that is almost always the intent — but "almost
/// always" is why this exists at all. Recovering from a mistake means reaching
/// for a copy from BEFORE it, and silently restoring the latest would hand
/// back the very state the user is trying to escape.
class RemoteBackupPicker extends StatelessWidget {
  const RemoteBackupPicker({super.key, required this.backups});

  final List<RemoteBackup> backups;

  static Future<RemoteBackup?> show(
    BuildContext context, {
    required List<RemoteBackup> backups,
  }) =>
      showDialog<RemoteBackup>(
        context: context,
        builder: (_) => RemoteBackupPicker(backups: backups),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Cuál quieres restaurar?'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: backups.length,
          itemBuilder: (context, index) {
            final backup = backups[index];
            return ListTile(
              leading: Icon(
                index == 0 ? Icons.schedule : Icons.history,
                color: index == 0 ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(_when(backup.modifiedAt)),
              subtitle: Text(
                '${_megabytes(backup.sizeBytes)}'
                '${index == 0 ? ' · el más reciente' : ''}',
              ),
              onTap: () => Navigator.of(context).pop(backup),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// The date the user recognises, not the server's filename.
  static String _when(DateTime at) =>
      '${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}';

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
