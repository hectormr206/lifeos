import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/offline_banner.dart';
import 'graph_node_notifier.dart';

/// One node's detail: facts, relations (each tappable — navigates to the
/// related node's own detail, pushing another `/graph/:id`), and
/// provenance ("Origen" — which conversations mentioned it).
class GraphNodeScreen extends ConsumerWidget {
  const GraphNodeScreen({required this.nodeId, super.key});

  final int nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = graphNodeNotifierProvider(nodeId);
    final state = ref.watch(provider);

    return Scaffold(
      appBar: AppBar(title: Text(state.detail?.node.label ?? 'Nodo')),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(provider.notifier).refresh(),
              child: _buildBody(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, GraphNodeUiState state) {
    if (state.loading) {
      return const _ScrollableCenter(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ScrollableCenter(child: Text(state.error!));
    }
    final detail = state.detail;
    if (detail == null) {
      return const _ScrollableCenter(child: Text('Nodo no encontrado.'));
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Text(detail.node.label, style: Theme.of(context).textTheme.headlineSmall),
        Text(detail.node.domain?.isNotEmpty == true ? '${detail.node.kind} · ${detail.node.domain}' : detail.node.kind),
        const SizedBox(height: 16),
        _Section(
          title: 'Hechos',
          empty: 'Sin hechos.',
          children: [for (final fact in detail.facts) ListTile(title: Text(fact.label))],
        ),
        _Section(
          title: 'Relaciones',
          empty: 'Sin relaciones.',
          children: [
            for (final relation in detail.relations)
              ListTile(
                title: Text('${relation.kind} · ${relation.otherLabel}'),
                subtitle: Text(relation.otherKind),
                onTap: () => context.push('/graph/${relation.otherId}'),
              ),
          ],
        ),
        _Section(
          title: 'Origen',
          empty: 'Sin conversaciones asociadas.',
          children: [for (final prov in detail.conversations) ListTile(title: Text(prov.userTextSnippet))],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.empty, required this.children});

  final String title;
  final String empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (children.isEmpty) Text(empty) else ...children,
        ],
      ),
    );
  }
}

/// Wraps non-list content (loading/error/not-found) in a scrollable so
/// [RefreshIndicator]'s pull-to-refresh keeps working (same pattern as
/// `DomainListScreen`'s `_ScrollableCenter`).
class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: constraints.maxHeight, child: Center(child: child)),
        ],
      ),
    );
  }
}
