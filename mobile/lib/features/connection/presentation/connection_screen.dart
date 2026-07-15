import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/connection_status.dart';
import 'connection_notifier.dart';

/// Settings screen for the pairing flow (design D6, spec
/// mobile-app-shell): enter the engine URL shown in the pairing QR's
/// `urls` list plus the short-lived code shown on the engine's `/setup`
/// page, or unpair an already-connected device.
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _engineUrlController = TextEditingController();
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _engineUrlController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Conexión')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: switch (connection) {
          ConnectionPaired(engineUrl: final engineUrl, deviceId: final deviceId) => _PairedView(
              engineUrl: engineUrl,
              deviceId: deviceId,
              onUnpair: () => ref.read(connectionNotifierProvider.notifier).unpair(),
            ),
          _ => _PairForm(
              engineUrlController: _engineUrlController,
              codeController: _codeController,
              connection: connection,
              onSubmit: () => ref.read(connectionNotifierProvider.notifier).pair(
                    engineUrl: _engineUrlController.text.trim(),
                    code: _codeController.text.trim(),
                  ),
            ),
        },
      ),
    );
  }
}

class _PairForm extends StatelessWidget {
  const _PairForm({
    required this.engineUrlController,
    required this.codeController,
    required this.connection,
    required this.onSubmit,
  });

  final TextEditingController engineUrlController;
  final TextEditingController codeController;
  final ConnectionStatus connection;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final status = connection;
    final isPairing = status is ConnectionPairing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Conecta con tu motor'),
        const SizedBox(height: 12),
        TextField(
          controller: engineUrlController,
          decoration: const InputDecoration(labelText: 'URL del motor'),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: codeController,
          decoration: const InputDecoration(labelText: 'Código de emparejamiento'),
        ),
        const SizedBox(height: 16),
        if (status is ConnectionError)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(status.message, style: const TextStyle(color: Colors.red)),
          ),
        ElevatedButton(
          onPressed: isPairing ? null : onSubmit,
          child: isPairing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Emparejar'),
        ),
      ],
    );
  }
}

class _PairedView extends StatelessWidget {
  const _PairedView({required this.engineUrl, required this.deviceId, required this.onUnpair});

  final String engineUrl;
  final String deviceId;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Motor: $engineUrl'),
        Text('Dispositivo: $deviceId'),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: onUnpair, child: const Text('Desconectar')),
      ],
    );
  }
}
