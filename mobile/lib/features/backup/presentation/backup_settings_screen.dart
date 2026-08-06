import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data_control/domain/backup_info.dart';
import '../../data_control/presentation/data_control_providers.dart';
import '../data/backup_host_client.dart';
import '../data/backup_host_config_store.dart';
import '../domain/backup_host_config.dart';
import '../../../core/security/passphrase_backup_sealer.dart';
import '../data/backup_service.dart';
import '../domain/backup_host_diagnosis.dart';
import 'passphrase_dialog.dart';
import 'remote_backup_picker.dart';

/// "Respaldos" screen: point the app at the backup server the user runs, check
/// the connection, and see exactly what is missing when it does not work.
///
/// The check reports WHICH rung failed rather than a generic error, because
/// each has a different fix and the user is the only one who can apply it.
class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({
    super.key,
    // Private initializing formals: callers still pass `store:` and `client:`
    // (Dart exposes the public name), while the fields stay private.
    this._store,
    this._client,
  });

  final BackupHostConfigStore? _store;
  final BackupHostClient? _client;

  @override
  ConsumerState<BackupSettingsScreen> createState() =>
      _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  late final BackupHostConfigStore _store =
      widget._store ?? BackupHostConfigStore();
  late final BackupHostClient _client = widget._client ?? BackupHostClient();

  final _addressController = TextEditingController();
  final _keyController = TextEditingController();

  BackupHostDiagnosis? _diagnosis;
  bool _checking = false;
  bool _loading = true;

  /// Serializes upload/restore: one operation against the store at a time.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addressController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await _store.load();
    if (!mounted) return;
    setState(() {
      _addressController.text = config.baseUrl;
      _keyController.text = config.accessKey;
      _loading = false;
    });
  }

  BackupHostConfig get _current => BackupHostConfig(
        baseUrl: _addressController.text,
        accessKey: _keyController.text,
      );

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    // Save first: a user who checks and then leaves should not lose what they
    // typed, and the check is only meaningful for what is actually stored.
    await _store.save(_current);
    final diagnosis = await _client.diagnose(_current);
    if (!mounted) return;
    setState(() {
      _diagnosis = diagnosis;
      _checking = false;
    });
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _backUpNow() async {
    final passphrase = await PassphraseDialog.show(
      context,
      title: 'Frase de recuperación',
      actionLabel: 'Respaldar',
      confirm: true,
    );
    if (passphrase == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final graphBackups = ref.read(graphBackupServiceProvider);
      final service = BackupService(
        uploader: HostUploader(client: _client),
        // A FRESH consistent copy, not whatever happens to be on disk:
        // VACUUM INTO snapshots the live DB transactionally.
        readArchive: () async {
          final local = await graphBackups.createBackup(
            kind: BackupKind.manual,
          );
          return File(local.path).readAsBytes();
        },
      );
      final name = await service.backUp(_current, passphrase: passphrase);
      _say('Respaldo guardado: $name');
    } on BackupHostException catch (error) {
      // Say what went wrong, not "error". The user is the only one who can
      // fix any of these.
      _say(error.message);
    } catch (error) {
      _say('No se pudo respaldar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromServer() async {
    setState(() => _busy = true);
    try {
      final graphBackups = ref.read(graphBackupServiceProvider);
      final available = await _client.list(_current);
      if (!mounted) return;
      if (available.isEmpty) {
        _say('No hay respaldos guardados en el servidor.');
        return;
      }
      // Newest first is the usual intent — but recovering from a mistake
      // means reaching for a copy from BEFORE it, so the user chooses.
      final chosen = available.length == 1
          ? available.single
          : await RemoteBackupPicker.show(context, backups: available);
      if (chosen == null || !mounted) return;

      final passphrase = await PassphraseDialog.show(
        context,
        title: 'Abrir «${chosen.name}»',
        actionLabel: 'Restaurar',
      );
      if (passphrase == null || !mounted) return;

      final sealed = await _client.download(_current, name: chosen.name);
      final opened = await PassphraseBackupSealer()
          .open(sealed, passphrase: passphrase);
      if (opened == null) {
        _say('Esa frase no abre el respaldo. Revisala e intentá de nuevo.');
        return;
      }

      // Land it as an ordinary local backup and hand the user to the existing
      // restore flow rather than swapping the live database from here. That
      // flow already snapshots the CURRENT data first, so a restore stays
      // reversible — a property worth more than saving one tap.
      final landed = await graphBackups.importArchive(opened, name: chosen.name);
      _say('Descargado y descifrado (${landed.sizeBytes} bytes). '
          'Restauralo desde «Copias de seguridad».');
    } on BackupHostException catch (error) {
      _say(error.message);
    } catch (error) {
      _say('No se pudo restaurar: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Respaldos')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Respaldos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _PassphraseWarning(),
          const SizedBox(height: 24),
          Text('Servidor', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _addressController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Dirección',
              hintText: 'http://10.66.66.1:8099',
              helperText: 'La dirección privada de tu servidor, por la VPN.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyController,
            autocorrect: false,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Clave de acceso',
              helperText: 'La que generaste al instalar el servidor.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _checking ? null : _checkConnection,
            icon: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering),
            label: Text(_checking ? 'Comprobando…' : 'Comprobar conexión'),
          ),
          if (_diagnosis != null) ...[
            const SizedBox(height: 16),
            _DiagnosisCard(diagnosis: _diagnosis!),
          ],
          // Only offered once the host has actually answered as ready. An
          // upload button that appears before the connection is proven invites
          // a user to believe a backup happened when nothing could have.
          if (_diagnosis?.isReady ?? false) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _backUpNow,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Respaldar ahora'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busy ? null : _restoreFromServer,
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('Restaurar desde el servidor'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Stated before the fields, not buried after them: it is the one thing that
/// cannot be undone later, and a user who learns it after losing the phrase
/// has learned it too late.
class _PassphraseWarning extends StatelessWidget {
  const _PassphraseWarning();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tu frase de recuperación',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Tus respaldos se cifran en este dispositivo con una frase que solo '
              'vos conocés. Ni el servidor ni nosotros podemos abrirlos.\n\n'
              'Si olvidás esa frase, los respaldos se pierden para siempre. '
              'No hay forma de recuperarlos. Anotala en un lugar seguro.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosisCard extends StatelessWidget {
  const _DiagnosisCard({required this.diagnosis});

  final BackupHostDiagnosis diagnosis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = diagnosis.isReady;
    return Card(
      color: ok ? scheme.secondaryContainer : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle : Icons.error_outline,
              color: ok ? scheme.onSecondaryContainer : scheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    diagnosis.message,
                    style: TextStyle(
                      color: ok
                          ? scheme.onSecondaryContainer
                          : scheme.onErrorContainer,
                    ),
                  ),
                  if (ok && diagnosis.freeBytes != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${_gigabytes(diagnosis.freeBytes!)} libres · '
                      '${diagnosis.backupCount ?? 0} respaldos guardados',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _gigabytes(int bytes) =>
      '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
