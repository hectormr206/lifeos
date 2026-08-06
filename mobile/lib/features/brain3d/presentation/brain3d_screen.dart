
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
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
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final payload = ref.watch(brain3dPayloadProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E13),
      appBar: AppBar(title: Text(l10n.brain3dTitle)),
      body: switch (payload) {
        AsyncData(:final value) when value.nodes.isEmpty =>
          _SummaryFallback(payload: value),
        AsyncData(:final value) => Brain3dView(
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
      child: Text(
        payload.nodes.isEmpty
            ? l10n.brain3dEmpty
            : l10n.brain3dSummary(payload.nodes.length, payload.edges.length),
        style: const TextStyle(color: Colors.white70),
        textAlign: TextAlign.center,
      ),
    );
  }
}
