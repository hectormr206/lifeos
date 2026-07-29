import 'package:flutter/material.dart';

import '../data/backup_host_client.dart';
import '../data/backup_host_config_store.dart';
import '../domain/backup_host_config.dart';
import '../domain/backup_host_diagnosis.dart';

/// "Respaldos" screen: point the app at the backup server the user runs, check
/// the connection, and see exactly what is missing when it does not work.
///
/// The check reports WHICH rung failed rather than a generic error, because
/// each has a different fix and the user is the only one who can apply it.
class BackupSettingsScreen extends StatefulWidget {
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
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  late final BackupHostConfigStore _store =
      widget._store ?? BackupHostConfigStore();
  late final BackupHostClient _client = widget._client ?? BackupHostClient();

  final _addressController = TextEditingController();
  final _keyController = TextEditingController();

  BackupHostDiagnosis? _diagnosis;
  bool _checking = false;
  bool _loading = true;

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
              'Tus respaldos se cifran en el teléfono con una frase que solo '
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
