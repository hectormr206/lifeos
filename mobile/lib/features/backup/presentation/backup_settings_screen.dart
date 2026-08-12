import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backups/data/automatic_backup_passphrase_store.dart';
import '../../backups/data/automatic_backup_settings_store.dart';
import '../../backups/data/automatic_backup_status_store.dart';
import '../../backups/data/workmanager_automatic_backup_work.dart';
import '../../backups/domain/automatic_backup_outcome.dart';
import '../../backups/domain/automatic_backup_status.dart';
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
    this._automaticSettingsStore,
    this._automaticStatusStore,
    this._automaticPassphraseStore,
    this._automaticBackupWork,
  });

  final BackupHostConfigStore? _store;
  final BackupHostClient? _client;
  final AutomaticBackupSettingsStore? _automaticSettingsStore;
  final AutomaticBackupStatusStore? _automaticStatusStore;
  final AutomaticBackupPassphraseStore? _automaticPassphraseStore;

  /// The OS scheduler seam. Injected in tests because the WorkManager plugin
  /// has no channel under `flutter_test` — and because whether registration
  /// LANDED now changes what this screen does, so it must be drivable.
  final WorkmanagerAutomaticBackupWork? _automaticBackupWork;

  @override
  ConsumerState<BackupSettingsScreen> createState() =>
      _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  late final BackupHostConfigStore _store =
      widget._store ?? BackupHostConfigStore();
  late final BackupHostClient _client = widget._client ?? BackupHostClient();
  late final AutomaticBackupSettingsStore _automaticSettingsStore =
      widget._automaticSettingsStore ?? AutomaticBackupSettingsStore();
  late final AutomaticBackupStatusStore _automaticStatusStore =
      widget._automaticStatusStore ?? AutomaticBackupStatusStore();
  late final AutomaticBackupPassphraseStore _automaticPassphraseStore =
      widget._automaticPassphraseStore ?? AutomaticBackupPassphraseStore();
  late final WorkmanagerAutomaticBackupWork _automaticBackupWork =
      widget._automaticBackupWork ?? WorkmanagerAutomaticBackupWork();

  final _addressController = TextEditingController();
  final _keyController = TextEditingController();

  BackupHostDiagnosis? _diagnosis;
  bool _checking = false;
  bool _loading = true;

  /// Serializes upload/restore: one operation against the store at a time.
  bool _busy = false;

  bool _automaticEnabled = false;
  AutomaticBackupStatus? _automaticStatus;

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
    final automaticEnabled = await _automaticSettingsStore.isEnabled();
    final automaticStatus = await _automaticStatusStore.load();
    if (!mounted) return;
    setState(() {
      _addressController.text = config.baseUrl;
      _keyController.text = config.accessKey;
      _automaticEnabled = automaticEnabled;
      _automaticStatus = automaticStatus;
      _loading = false;
    });
  }

  /// Turning ON is NOT optimistic, unlike turning OFF: it requires capturing
  /// the sealing passphrase into secure storage FIRST (owner decision, 3.9),
  /// and the switch must not visually move until that has actually
  /// succeeded — a switch that reads "on" while nothing was stored to back
  /// up with is the worst outcome this feature can produce.
  Future<void> _setAutomaticEnabled(bool enabled) async {
    if (!enabled) {
      // Optimistic here is fine: disabling only ever makes the feature MORE
      // safe, and the setting alone (checked first by the scheduler) is
      // already sufficient to stop future runs even before the delete below
      // completes.
      setState(() => _automaticEnabled = false);
      await _automaticSettingsStore.setEnabled(false);
      // The opt-out must actually remove the secret, not just stop the
      // scheduler — a switch labelled "off" that leaves the passphrase
      // sitting in the keystore would be lying about what "off" means.
      try {
        await _automaticPassphraseStore.delete();
      } catch (_) {
        // Best-effort: the setting flip above already halts future runs
        // regardless (checked before the passphrase is ever read), so a
        // delete failure here does not reopen the safety hole — it only
        // means secret hygiene, not correctness, is imperfect this time.
      }
      final cancelled = await _automaticBackupWork.cancel();
      if (!cancelled) {
        // Far less dangerous than a failed registration — the runner reads
        // the setting flipped above BEFORE anything else and records
        // `skippedDisabled` — but an instruction the OS did not take is
        // still said out loud rather than swallowed.
        _say('Se desactivó el respaldo automático, pero el sistema no '
            'confirmó la cancelación de la tarea programada. No se hará '
            'ningún respaldo (la opción está apagada); si quieres, reinicia '
            'la app para que quede limpio.');
      }
      return;
    }

    final passphrase = await PassphraseDialog.show(
      context,
      title: 'Frase de recuperación',
      actionLabel: 'Activar',
      confirm: true,
    );
    if (passphrase == null || !mounted) return; // backed out — stays off

    try {
      await _automaticPassphraseStore.save(passphrase);
    } catch (_) {
      // On Linux this is the concrete case: no gnome-keyring/kwallet
      // running (see tools/install-linux.sh's warning). Whatever the cause,
      // fail LOUDLY and name the missing piece — never flip the switch on a
      // secret that was not actually stored, and never log/show the
      // passphrase itself in this or any other error path.
      _say('No se pudo activar el respaldo automático: no hay un gestor de '
          'llaves disponible en este dispositivo (falta un gestor de '
          'llaves como gnome-keyring o kwallet) para guardar la frase de '
          'forma segura. Seguí usando "Respaldar ahora" mientras tanto.');
      return;
    }

    // The OS registration comes BEFORE the setting is stored, for the same
    // reason the passphrase capture does: the switch must not move over a
    // step that did not actually happen. WorkManager refusing the periodic
    // task means the backup will never fire, and nothing else in the app
    // would ever notice — the constraint-carrying registration IS the
    // feature (see `workmanager_automatic_backup_work.dart`).
    if (!await _automaticBackupWork.schedule()) {
      // Roll the activation back completely, including the secret: "off"
      // must not leave the sealing phrase in the keystore (same contract as
      // turning the switch off by hand).
      try {
        await _automaticPassphraseStore.delete();
      } catch (_) {
        // Best-effort hygiene; the switch stays off regardless.
      }
      _say('No se pudo activar el respaldo automático: no se pudo programar '
          'la tarea periódica en este dispositivo (el sistema la rechazó). '
          'Seguí usando "Respaldar ahora" mientras tanto.');
      return;
    }
    await _automaticSettingsStore.setEnabled(true);
    if (!mounted) return;
    setState(() => _automaticEnabled = true);
  }

  /// A single line describing the last automatic run, or null before the
  /// first one ever fires. [AutomaticBackupOutcome.skippedVpnUnknown] gets
  /// its own loud framing — a plain skip and "I could not tell" are
  /// different claims (see `vpn_gate.dart`'s doc), and the user needs to
  /// know which one happened.
  String? _automaticStatusMessage() {
    final status = _automaticStatus;
    if (status == null) return null;
    return switch (status.outcome) {
      AutomaticBackupOutcome.succeeded => 'Último respaldo automático: '
          '${status.at.toLocal()}',
      AutomaticBackupOutcome.skippedVpnDown =>
        'Respaldo automático pendiente: no estabas conectado a la VPN.',
      AutomaticBackupOutcome.skippedVpnUnknown => 'No se pudo determinar si '
          'estabas en la VPN — no se hizo el respaldo automático.',
      AutomaticBackupOutcome.skippedDisabled =>
        'El respaldo automático está desactivado.',
      AutomaticBackupOutcome.waitingForWifi => 'Respaldo automático en '
          'espera de Wi-Fi (el archivo pesa demasiado para datos móviles).',
      AutomaticBackupOutcome.failed =>
        'Falló el último respaldo automático: ${status.message ?? "error desconocido"}',
      AutomaticBackupOutcome.passphraseUnavailable => 'Respaldo automático '
          'pendiente: no se pudo leer la frase de forma segura en este '
          'dispositivo.',
    };
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
        _say('Esa frase no abre el respaldo. Revísala e inténtalo de nuevo.');
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
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Text('Respaldo automático', style: Theme.of(context).textTheme.titleMedium),
          // The ONE deliberate exception to "the user activates things
          // himself" — so unlike every other automatic feature in this app,
          // it needs an explicit off switch that persists (spec).
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _automaticEnabled,
            onChanged: _setAutomaticEnabled,
            title: const Text('Respaldar automáticamente por la VPN'),
            subtitle: const Text(
              'Solo cuando este dispositivo puede probar que está conectado '
              'a tu VPN, y con Wi-Fi si el respaldo es pesado.',
            ),
          ),
          if (_automaticStatusMessage() != null) ...[
            const SizedBox(height: 4),
            Text(
              _automaticStatusMessage()!,
              style: Theme.of(context).textTheme.bodySmall,
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
              'tú conoces. Ni el servidor ni nosotros podemos abrirlos.\n\n'
              'Si olvidas esa frase, los respaldos se pierden para siempre. '
              'No hay forma de recuperarlos. Anótala en un lugar seguro.',
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
