import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/widgets.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_tokens.dart';
import '../domain/backup_info.dart';
import 'data_control_providers.dart';

/// "Copias de seguridad" (data-control kit, part A) — reachable from the
/// Settings hub, offline, not pairing-gated. Two sections (Automáticas /
/// Manuales) with date + size; tap a backup to start the REVERSIBLE restore
/// flow; manual + pre-restore copies can be deleted individually.
class BackupsScreen extends ConsumerStatefulWidget {
  const BackupsScreen({super.key});

  @override
  ConsumerState<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends ConsumerState<BackupsScreen> {
  /// Serializes create/restore/delete: one data-control operation at a time.
  bool _working = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs [operation] guarded by the Axi-busy check + the local serial lock,
  /// then refreshes the list. Any failure surfaces localized.
  Future<void> _run(
    Future<String?> Function(AppLocalizations l10n) operation,
  ) async {
    final l10n = AppLocalizations.of(context);
    if (_working) return;
    if (isDataControlBusy(ref)) {
      _snack(l10n.dataControlBusy);
      return;
    }
    setState(() => _working = true);
    try {
      final message = await operation(l10n);
      if (message != null) _snack(message);
    } catch (error) {
      _snack(l10n.backupsOperationFailed('$error'));
    } finally {
      if (mounted) setState(() => _working = false);
      ref.invalidate(backupsListProvider);
    }
  }

  Future<void> _createNow() => _run((l10n) async {
    await ref
        .read(graphBackupServiceProvider)
        .createBackup(kind: BackupKind.manual);
    return l10n.backupsCreated;
  });

  Future<void> _delete(BackupInfo backup) => _run((l10n) async {
    await ref.read(graphBackupServiceProvider).deleteBackup(backup);
    return l10n.backupsDeleted;
  });

  Future<void> _confirmRestore(BackupInfo backup) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.backupsRestoreTitle),
        content: Text(l10n.backupsRestoreBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.backupsRestoreConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run((l10n) async {
      await ref.read(graphBackupServiceProvider).restoreBackup(backup);
      return l10n.backupsRestored;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final backups = ref.watch(backupsListProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupsTitle)),
      body: backups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text(l10n.backupsOperationFailed('$error'))),
        data: (all) {
          final autos = all.where((b) => b.kind == BackupKind.auto).toList();
          final manuals = all.where((b) => b.kind != BackupKind.auto).toList();
          return PageBody(
            children: [
              FilledButton.icon(
                onPressed: _working ? null : _createNow,
                icon: _working
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(l10n.backupsCreateNow),
              ),
              const SizedBox(height: Space.lg),
              // Everything above this line lives on the phone, and dies with
              // it. Offer the off-device destination right here rather than in
              // a distant settings entry: a user looking at their backups is
              // exactly the user who should learn these copies are not safe
              // from losing the device.
              // TODO(i18n): hardcoded neutral Spanish pending the i18n sweep.
              GroupedList(
                children: [
                  GroupedRow(
                    icon: Icons.cloud_upload_outlined,
                    title: 'Guardar en mi servidor',
                    subtitle:
                        'Estas copias viven solo en este dispositivo. Envía una copia '
                        'cifrada a un servidor tuyo.',
                    subtitleMaxLines: null,
                    onTap: () => context.push('/settings/backups/server'),
                  ),
                ],
              ),
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Space.lg),
                  child: Text(
                    l10n.backupsEmpty,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (autos.isNotEmpty) ...[
                SectionHeader(l10n.backupsAutoSection),
                GroupedList(
                  children: [
                    for (final backup in autos)
                      _BackupTile(
                        backup: backup,
                        // Automatic copies rotate on their own (retention cap);
                        // only manual/pre-restore copies expose delete.
                        onDelete: null,
                        onTap: _working ? null : () => _confirmRestore(backup),
                      ),
                  ],
                ),
              ],
              if (manuals.isNotEmpty) ...[
                SectionHeader(l10n.backupsManualSection),
                GroupedList(
                  children: [
                    for (final backup in manuals)
                      _BackupTile(
                        backup: backup,
                        onDelete: _working ? null : () => _delete(backup),
                        onTap: _working ? null : () => _confirmRestore(backup),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _BackupTile extends StatelessWidget {
  const _BackupTile({required this.backup, this.onDelete, this.onTap});

  final BackupInfo backup;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String formatDate(DateTime t) =>
      '${_two(t.day)}/${_two(t.month)}/${t.year} ${_two(t.hour)}:${_two(t.minute)}';

  static String formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GroupedRow(
      icon: backup.isPreRestore
          ? Icons.settings_backup_restore
          : Icons.archive_outlined,
      title: formatDate(backup.createdAt),
      subtitle: backup.isPreRestore
          ? '${l10n.backupsPreRestoreLabel} · ${formatSize(backup.sizeBytes)}'
          : formatSize(backup.sizeBytes),
      trailing: onDelete == null
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.backupsDeleteTooltip,
              onPressed: onDelete,
            ),
      onTap: onTap,
    );
  }
}
