import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/digest.dart';
import 'insights_notifier.dart';

/// The daily/weekly digest preview — the "visible soul" slice's read-only
/// insights surface (see `InsightsRepository`'s scope note: only the
/// non-mutating `GET /api/v1/insights/preview` is used; no domain summaries
/// are fabricated into a synthetic "insights" shape).
class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(insightsNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Resumen')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(insightsNotifierProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _CadenceToggle(
              cadence: state.cadence,
              onChanged: (cadence) => ref.read(insightsNotifierProvider.notifier).setCadence(cadence),
            ),
            const SizedBox(height: 16),
            _buildBody(context, ref, state),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, InsightsUiState state) {
    if (state.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.error != null) {
      return Column(
        children: [
          Text(state.error!),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => ref.read(insightsNotifierProvider.notifier).refresh(),
            child: const Text('Reintentar'),
          ),
        ],
      );
    }
    final digest = state.digest;
    if (digest == null) {
      return const Text('Aún no hay un resumen disponible.');
    }
    return _DigestView(digest: digest);
  }
}

class _CadenceToggle extends StatelessWidget {
  const _CadenceToggle({required this.cadence, required this.onChanged});

  final String cadence;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'daily', label: Text('Diario')),
        ButtonSegment(value: 'weekly', label: Text('Semanal')),
      ],
      selected: {cadence},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

class _DigestView extends StatelessWidget {
  const _DigestView({required this.digest});

  final DigestModel digest;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(digest.body),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                Chip(label: Text('${digest.sectionsCount} secciones')),
                Chip(label: Text('${digest.patternsCount} patrones')),
                Chip(label: Text('${digest.correlationsCount} correlaciones')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
