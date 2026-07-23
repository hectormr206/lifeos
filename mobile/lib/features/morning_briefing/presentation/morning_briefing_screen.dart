import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/lifeos_theme.dart';
import '../domain/morning_briefing.dart';
import 'morning_briefing_notifier.dart';

/// The ON-DEVICE "Boletín" screen: shows the latest briefing the phone
/// generated with its local model, a "Generar boletín ahora" button that runs
/// the pipeline (with progress), and access to the source-URL editor.
///
/// Deliberately separate from the pairing-gated Boletines viewer
/// (`/briefings`, features/briefings) which mirrors the laptop dashboard: this
/// one is produced entirely on device and needs no engine connection.
class MorningBriefingScreen extends ConsumerWidget {
  const MorningBriefingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(morningBriefingNotifierProvider);
    final notifier = ref.read(morningBriefingNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Boletín'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Fuentes',
            onPressed: () => context.push('/settings/briefing/sources'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (state.isGenerating)
            _ProgressCard(label: state.progressLabel ?? 'Generando…')
          else if (state.phase == BriefingPhase.error && state.error != null)
            _ErrorCard(message: state.error!),
          if (state.briefing != null) ...[
            _BriefingHeader(briefing: state.briefing!),
            const SizedBox(height: 12),
            for (final item in state.briefing!.items) _BriefingItemCard(item: item),
          ] else if (!state.isGenerating && state.phase != BriefingPhase.error)
            const _EmptyState(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isGenerating ? null : notifier.generate,
        icon: state.isGenerating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.auto_awesome),
        label: Text(state.isGenerating ? 'Generando…' : 'Generar boletín ahora'),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          const Icon(Icons.wb_sunny_outlined, size: 56, color: LifeOSColors.teal),
          const SizedBox(height: 16),
          Text('Aún no hay boletín', style: textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Toca "Generar boletín ahora" y Axi leerá tus fuentes y las resumirá en el dispositivo.',
            style: textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _BriefingHeader extends StatelessWidget {
  const _BriefingHeader({required this.briefing});

  final OnDeviceBriefing briefing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Boletín matutino', style: textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          _formatTimestamp(briefing.generatedAt),
          style: textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor),
        ),
        if (briefing.intro.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(briefing.intro, style: textTheme.bodyLarge),
        ],
      ],
    );
  }

  static String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Generado el ${two(dt.day)}/${two(dt.month)}/${dt.year} a las ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _BriefingItemCard extends StatelessWidget {
  const _BriefingItemCard({required this.item});

  final BriefingItem item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.sourceTitle, style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(item.summary, style: textTheme.bodyMedium),
            if (item.url.isNotEmpty) ...[
              const SizedBox(height: 12),
              InkWell(
                onTap: () => _copyLink(context, item.url),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.link, size: 16, color: LifeOSColors.teal),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium?.copyWith(color: LifeOSColors.teal),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copyLink(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Enlace copiado al portapapeles')),
    );
  }
}
