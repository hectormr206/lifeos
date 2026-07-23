import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graph/graph_records.dart';
import 'local_graph_browser_screen.dart' show localGraphKindLabel, localGraphFormatDate;
import 'local_graph_notifier.dart';

/// One on-device node's detail: its label, kind/domain/date, the `data` JSON
/// payload, and its in/out relations — each tappable to navigate one hop to the
/// related node's own detail (pushing another `/settings/graph/:uuid`). Reads
/// the local store only.
// TODO(i18n): user-facing strings here are hardcoded neutral Spanish pending
// the i18n sweep.
class LocalGraphNodeScreen extends ConsumerWidget {
  const LocalGraphNodeScreen({required this.nodeUuid, super.key});

  final String nodeUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localGraphNodeProvider(nodeUuid));

    return Scaffold(
      appBar: AppBar(
        title: Text(async.value?.node.label ?? 'Nodo'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No se pudo cargar el nodo: $error'),
          ),
        ),
        data: (detail) {
          if (detail == null) {
            return const Center(child: Text('Nodo no encontrado.'));
          }
          return _DetailBody(detail: detail);
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.detail});

  final LocalGraphNodeDetail detail;

  @override
  Widget build(BuildContext context) {
    final node = detail.node;
    final domain = node.domain;
    final meta = <String>[
      localGraphKindLabel(node.kind),
      if (domain != null && domain.isNotEmpty) domain,
      localGraphFormatDate(node.createdAt),
    ].join(' · ');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          node.label.isNotEmpty ? node.label : '(sin título)',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(meta, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        _Section(
          title: 'Detalles',
          empty: 'Sin detalles.',
          children: _dataTiles(node),
        ),
        _Section(
          title: 'Relaciones',
          empty: 'Sin relaciones.',
          children: [
            for (final rel in detail.relations)
              ListTile(
                leading: Icon(
                  rel.outgoing ? Icons.arrow_forward : Icons.arrow_back,
                  size: 20,
                ),
                title: Text('${rel.relation} · ${rel.otherLabel}'),
                subtitle: Text(localGraphKindLabel(rel.otherKind)),
                onTap: () => context.push('/settings/graph/${rel.otherUuid}'),
              ),
          ],
        ),
      ],
    );
  }

  /// Render the node's `data` map as simple key/value rows.
  List<Widget> _dataTiles(GraphNodeRecord node) {
    if (node.data.isEmpty) return const [];
    return [
      for (final entry in node.data.entries)
        ListTile(
          dense: true,
          title: Text(entry.key),
          subtitle: Text(_stringify(entry.value)),
        ),
    ];
  }

  static String _stringify(Object? value) {
    if (value == null) return '—';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
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
