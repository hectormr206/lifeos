import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stt/domain/stt_model.dart';
import '../../stt/presentation/stt_providers.dart';
import 'dictation_providers.dart';

// TODO(i18n): copy hardcoded in neutral Spanish, like the rest of the app.

/// Settings › Teclado Axi (system-wide dictation).
///
/// Guides the user through enabling the native Axi keyboard (an Android IME
/// that types with the voice): 1) enable it in system settings, 2) switch to
/// it from the keyboard picker, plus the on-device Whisper voice-model status
/// (the keyboard reuses the exact files this app downloads — nothing extra).
///
/// Both steps happen in SYSTEM UI, so their status is re-checked when the app
/// resumes (same pattern as PermissionsScreen).
class DictationSetupScreen extends ConsumerStatefulWidget {
  const DictationSetupScreen({super.key});

  @override
  ConsumerState<DictationSetupScreen> createState() => _DictationSetupScreenState();
}

class _DictationSetupScreenState extends ConsumerState<DictationSetupScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from system settings / keyboard picker → re-probe both steps.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(dictationImeStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imeStatus = ref.watch(dictationImeStatusProvider);
    final modelStatus = ref.watch(sttModelDownloadProvider);
    final enabled = imeStatus.asData?.value.enabled ?? false;
    final selected = imeStatus.asData?.value.selected ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Teclado Axi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Dicta en cualquier app con la voz. El teclado Axi transcribe '
            'EN TU TELÉFONO con el modelo de voz local: el audio y el texto '
            'nunca salen del dispositivo.',
          ),
          const SizedBox(height: 16),
          _StepCard(
            done: enabled,
            title: '1. Activa el teclado Axi',
            subtitle: 'Enciende «Axi · Dictado LifeOS» en los ajustes del sistema.',
            buttonLabel: 'Abrir ajustes de teclado',
            onPressed: () => ref.read(dictationChannelProvider).openImeSettings(),
          ),
          const SizedBox(height: 12),
          _StepCard(
            done: selected,
            title: '2. Cambia al teclado Axi',
            subtitle: 'Elige «Axi» en el selector de teclados. Puedes volver a tu '
                'teclado normal con el botón 🌐 del propio teclado Axi.',
            buttonLabel: 'Elegir teclado',
            onPressed: enabled
                ? () => ref.read(dictationChannelProvider).showImePicker()
                : null,
          ),
          const SizedBox(height: 12),
          _ModelCard(status: modelStatus),
          const SizedBox(height: 16),
          const Text(
            'Cómo se usa: en cualquier campo de texto, toca el micrófono para '
            'empezar a dictar y tócalo de nuevo para terminar. En dictados '
            'largos el texto va apareciendo por frases mientras hablas.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// One numbered setup step with a check when done and an action button.
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.done,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
  });

  final bool done;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: done ? Colors.teal : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(subtitle),
            const SizedBox(height: 12),
            FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}

/// Voice-model status card. The keyboard reads the same Whisper files the app
/// downloads, so "download here once" unlocks dictation everywhere.
class _ModelCard extends ConsumerWidget {
  const _ModelCard({required this.status});

  final SttModelStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, color, text) = switch (status) {
      SttModelReady() => (Icons.check_circle, Colors.teal, 'Modelo de voz listo'),
      SttModelDownloading(:final progress) => (
          Icons.downloading,
          null,
          'Descargando modelo de voz… ${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
        ),
      SttModelFailed() => (Icons.error_outline, Colors.redAccent, 'La descarga falló'),
      SttModelAbsent() => (
          Icons.mic_off,
          null,
          'Modelo de voz no descargado (el teclado lo necesita)',
        ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(text)),
              ],
            ),
            if (status is SttModelAbsent || status is SttModelFailed) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.read(sttModelDownloadProvider.notifier).download(),
                child: const Text('Descargar modelo de voz'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
