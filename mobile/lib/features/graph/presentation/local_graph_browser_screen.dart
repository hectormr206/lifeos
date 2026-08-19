import 'package:flutter/material.dart';

import '../../../core/graph/domain_labels.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graph/graph_records.dart';
import 'local_graph_notifier.dart';

/// The ON-DEVICE memory browser (roadmap SLICE C5): lists the nodes C1 writes
/// locally — grouped/filterable by kind (facts, conversations, people…), with
/// a substring search — and opens each node's detail at
/// `/settings/graph/:uuid`. Reads the local encrypted store only; needs no
/// pairing and works fully offline.
// TODO(i18n): user-facing strings here are hardcoded neutral Spanish pending
// the i18n sweep.
class LocalGraphBrowserScreen extends ConsumerStatefulWidget {
  const LocalGraphBrowserScreen({super.key});

  @override
  ConsumerState<LocalGraphBrowserScreen> createState() =>
      _LocalGraphBrowserScreenState();
}

class _LocalGraphBrowserScreenState
    extends ConsumerState<LocalGraphBrowserScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search() =>
      ref.read(localGraphListProvider.notifier).search(_controller.text);

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(localGraphListProvider);
    final activeKind = async.value?.kind;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi memoria'),
        actions: [
          // Cerebro 3D of the same on-device graph this screen lists.
          IconButton(
            icon: const Icon(Icons.hub_outlined),
            tooltip: 'Ver Cerebro 3D',
            onPressed: () => context.push('/brain3d'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Buscar en mi memoria…',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
          ),
          _KindFilterBar(
            activeKind: activeKind,
            onSelected: (kind) =>
                ref.read(localGraphListProvider.notifier).setKind(kind),
          ),
          Expanded(
            child: async.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No se pudo abrir tu memoria: $error'),
                ),
              ),
              data: (state) => _NodeList(state: state),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal "Todos / Hechos / Conversaciones / …" filter chips.
class _KindFilterBar extends StatelessWidget {
  const _KindFilterBar({required this.activeKind, required this.onSelected});

  final String? activeKind;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              label: const Text('Todos'),
              selected: activeKind == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final entry in kLocalGraphKinds)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                label: Text(entry.label),
                selected: activeKind == entry.kind,
                onSelected: (_) => onSelected(entry.kind),
              ),
            ),
        ],
      ),
    );
  }
}

class _NodeList extends StatelessWidget {
  const _NodeList({required this.state});

  final LocalGraphListState state;

  @override
  Widget build(BuildContext context) {
    if (state.nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.isSearching
                ? 'Sin resultados para "${state.query.trim()}".'
                : 'Aún no hay nada en tu memoria. A medida que uses Axi, '
                    'aquí aparecerá lo que recuerde por ti.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: state.nodes.length,
      itemBuilder: (context, index) {
        final node = state.nodes[index];
        return ListTile(
          title: Text(node.label.isNotEmpty ? node.label : '(sin título)'),
          subtitle: Text(_subtitle(node)),
          onTap: () => context.push('/settings/graph/${node.uuid}'),
        );
      },
    );
  }

  String _subtitle(GraphNodeRecord node) {
    final kindLabel = _kindLabel(node.kind);
    final domain = node.domain;
    final parts = <String>[
      kindLabel,
      // Translated, not raw: this screen showed 'health' and 'relationships'
      // beside the user's own memories.
      if (domain != null && domain.isNotEmpty) domainLabel(domain),
      _formatDate(node.createdAt),
    ];
    return parts.join(' · ');
  }
}

/// Spanish label for a known kind, falling back to the raw kind.
String _kindLabel(String kind) {
  for (final entry in kLocalGraphKinds) {
    if (entry.kind == kind) return entry.label;
  }
  return kind;
}

/// Local `dd/MM/yyyy` — no intl dependency needed for a short date.
String _formatDate(DateTime utc) {
  final d = utc.toLocal();
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}

/// Exposed for the detail screen so kind labelling stays consistent.
String localGraphKindLabel(String kind) => _kindLabel(kind);

/// Exposed for the detail screen so date formatting stays consistent.
String localGraphFormatDate(DateTime utc) => _formatDate(utc);
