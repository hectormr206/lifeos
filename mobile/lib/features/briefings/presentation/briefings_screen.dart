import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import '../domain/briefing.dart';
import 'briefings_notifier.dart';

/// Boletines — agentic briefings. Mirrors `BodyScreen`'s expandable-tile
/// pattern: one card per briefing (agentic recurring reminder), expanded in
/// place to show its latest fired result. There is no per-id detail route
/// on the engine (see `BriefingsRepository`'s scope note), so the "detail"
/// view is rendered entirely from the same list item.
class BriefingsScreen extends ConsumerWidget {
  const BriefingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(briefingsNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Boletines')),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(briefingsNotifierProvider.notifier).refresh(),
              child: _buildBody(ref, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(WidgetRef ref, BriefingsUiState state) {
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
              onPressed: () => ref.read(briefingsNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.briefings.isEmpty) {
      return const _ScrollableCenter(child: Text('Aún no tienes boletines.'));
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.briefings.length,
      itemBuilder: (context, index) => _BriefingTile(briefing: state.briefings[index]),
    );
  }
}

/// Wraps non-list content (loading/error/empty) in a scrollable so
/// [RefreshIndicator]'s pull-to-refresh keeps working.
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

class _BriefingTile extends StatelessWidget {
  const _BriefingTile({required this.briefing});

  final BriefingModel briefing;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: Icon(
        briefing.result == null ? Icons.schedule : (briefing.result!.ok ? Icons.check_circle : Icons.error),
        color: briefing.result == null ? Colors.grey : (briefing.result!.ok ? Colors.green : Colors.red),
      ),
      title: Text(briefing.message),
      subtitle: Text(_subtitleFor(briefing)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _ResultDetail(result: briefing.result),
          ),
        ),
      ],
    );
  }

  String _subtitleFor(BriefingModel briefing) {
    final when = _formatTimestamp(briefing.whenTs);
    return briefing.recurrence != null ? '$when · recurrente' : when;
  }

  String _formatTimestamp(DateTime ts) {
    final local = ts.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _ResultDetail extends StatelessWidget {
  const _ResultDetail({required this.result});

  final BriefingResult? result;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    if (result == null) {
      return const Text('Aún no se ha ejecutado.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.title != null) ...[
          Text(result.title!, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
        ],
        if (result.summary != null) ...[
          Text(result.summary!),
          const SizedBox(height: 8),
        ],
        for (final item in result.items) Text('• $item'),
      ],
    );
  }
}
