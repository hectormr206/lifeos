
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../../../core/graph/graph_records.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/brain3d_payload.dart';
import '../domain/brain3d_palette.dart';
import 'brain3d_view.dart';

/// The Cerebro 3D payload built from the ON-DEVICE graph (read side only).
/// A plain FutureProvider — recomputed on each screen entry via `ref.refresh`
/// is unnecessary: autoDispose drops it when the screen closes so the next
/// visit re-reads the (possibly grown) local graph.
final brain3dPayloadProvider = FutureProvider.autoDispose<Brain3dPayload>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return buildBrain3dPayload(store);
});

/// Cerebro 3D — mobile parity of the laptop's /brain3d: an interactive
/// force-directed 3D rendering of the user's LOCAL memory graph so "Axi está
/// relacionando todo lo que le cuentas" is visible on the phone too.
///
/// Rendering reuses the laptop's vendored 3d-force-graph bundle (three.js
/// included) inside an offline WebView (assets/brain3d/*, no CDN); the graph
/// data is injected as JSON via `axiLoadGraph(...)` once the page loads.
/// Node taps open the in-page info panel; orbit/pinch come from the lib's
/// native touch controls. Platforms without a WebView implementation (host
/// tests, Linux) get a textual summary fallback instead.
class Brain3dScreen extends ConsumerStatefulWidget {
  const Brain3dScreen({super.key});

  @override
  ConsumerState<Brain3dScreen> createState() => _Brain3dScreenState();
}

class _Brain3dScreenState extends ConsumerState<Brain3dScreen> {
  /// The node whose details are open. Null closes the panel and clears every
  /// label, which is what makes the graph readable again.
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final payload = ref.watch(brain3dPayloadProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E13),
      appBar: AppBar(
        title: Text(l10n.brain3dTitle),
        // The count, as the desktop Cerebro has always shown it. Without it a
        // sparse-looking graph is indistinguishable from a broken one — which
        // cost this session two wrong fixes.
        actions: [
          if (payload case AsyncData(:final value))
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${value.nodes.length} · ${value.edges.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: switch (payload) {
        // Fewer than three memories is not a graph — it is one or two dots in
        // a black field, which reads as a broken screen rather than as "you
        // have told Axi two things". Reported twice from a laptop: two specks
        // twenty pixels apart in the middle of 2560x1430.
        //
        // A graph is a picture of RELATIONSHIPS. With nothing to relate, a
        // sentence is the honest rendering — and it says how many there are,
        // so an unexpected number is visible instead of being mistaken for a
        // rendering fault.
        AsyncData(:final value) when value.nodes.length < 3 =>
          _SummaryFallback(payload: value),
        AsyncData(:final value) => Stack(
            children: [
              Positioned.fill(
                child: Brain3dView(
                  selectedId: _selectedId,
                  onSelect: (id) => setState(() => _selectedId = id),
                  nodes: [
                    for (final n in value.nodes)
                      Brain3dVisualNode(
                        id: n.uuid,
                        label: n.label,
                        color: brain3dColorFor(domain: n.domain, kind: n.kind),
                      ),
                  ],
                  edges: [
                    for (final e in value.edges) (e.srcUuid, e.dstUuid),
                  ],
                ),
              ),
              if (_selectedId != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _NodeDetails(
                    node: value.nodes.firstWhere(
                      (n) => n.uuid == _selectedId,
                      orElse: () => value.nodes.first,
                    ),
                    relations: value.edges
                        .where((e) =>
                            e.srcUuid == _selectedId || e.dstUuid == _selectedId)
                        .length,
                    onClose: () => setState(() => _selectedId = null),
                  ),
                ),
            ],
          ),
        AsyncError(:final error) =>
          Center(child: Text('$error', style: const TextStyle(color: Colors.white70))),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// Shown when the graph is EMPTY: a blank canvas would read as a bug rather
/// than as "you have not told Axi anything yet".
class _SummaryFallback extends StatelessWidget {
  const _SummaryFallback({required this.payload});

  final Brain3dPayload payload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          payload.nodes.isEmpty
              ? l10n.brain3dEmpty
              // Says WHY the screen is a sentence and not a graph, and how many
              // memories there are — so an unexpected number is visible instead
              // of being mistaken for a rendering fault.
              : l10n.brain3dSparse(payload.nodes.length),
          style: const TextStyle(color: Colors.white70, fontSize: 16),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// What a memory IS, shown when you tap it.
///
/// The desktop Cerebro has had this from the start: a panel with the label, its
/// kind and domain, when it was created and how many relationships it has. The
/// phone port shipped without it and painted every label permanently instead —
/// less useful AND uglier.
class _NodeDetails extends StatelessWidget {
  const _NodeDetails({
    required this.node,
    required this.relations,
    required this.onClose,
  });

  final GraphNodeRecord node;
  final int relations;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: const Color(0xFF161A22),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.label,
                      style: text.titleMedium?.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final tag in [node.kind, ?node.domain])
                          Chip(
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: const Color(0xFF222833),
                            labelStyle: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                            side: BorderSide.none,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      // The date the memory was BORN — which now travels
                      // between devices, so it reads the same on both.
                      'Creado: ${_day(node.createdAt)}  ·  '
                      '${relations == 1 ? "1 relación" : "$relations relaciones"}',
                      style: text.bodySmall?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _day(DateTime t) =>
      '${t.day}/${t.month}/${t.year}';
}
