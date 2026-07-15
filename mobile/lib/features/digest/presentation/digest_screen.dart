import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import '../domain/today_digest.dart';
import 'digest_notifier.dart';

/// "Resumen de hoy" — the smart daily digest (a DIFFERENT feature than
/// `InsightsScreen`'s narrated daily/weekly digest preview; see
/// `DigestRepository`'s scope note). Shows today's raw counts
/// (conversations/meetings/facts/events) as chips plus the optional
/// brain-narrated summary and the day's top facts.
class DigestScreen extends ConsumerWidget {
  const DigestScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(digestNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Resumen de hoy')),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(digestNotifierProvider.notifier).refresh(),
              child: _buildBody(ref, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(WidgetRef ref, DigestUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ScrollableCenter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => ref.read(digestNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    final digest = state.digest;
    if (digest == null) {
      return const _ScrollableCenter(child: Text('Aún no hay un resumen de hoy disponible.'));
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [_DigestView(digest: digest)],
    );
  }
}

class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(child: child),
          ),
        ],
      ),
    );
  }
}

class _DigestView extends StatelessWidget {
  const _DigestView({required this.digest});

  final TodayDigest digest;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(digest.date, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('${digest.conversationsCount} conversaciones')),
                Chip(label: Text('${digest.meetingsCount} reuniones')),
                Chip(label: Text('${digest.factsAddedCount} hechos nuevos')),
                Chip(label: Text('${digest.eventsCriticalCount} eventos críticos')),
                Chip(label: Text('${digest.eventsErrorCount} eventos con error')),
              ],
            ),
            const SizedBox(height: 16),
            Text(digest.generatedSummary ?? 'Aún no hay un resumen narrado disponible.'),
            if (digest.topFacts.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Hechos destacados', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final fact in digest.topFacts) Text('• ${fact.label}'),
            ],
          ],
        ),
      ),
    );
  }
}
