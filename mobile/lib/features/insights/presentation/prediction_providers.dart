/// Riverpod wiring for the DETERMINISTIC prediction layer.
///
/// Reads the on-device graph store (the same store [LocalDomainRepository] wraps)
/// and runs the pure [detectPatterns] engine over every stored `fact` node. No
/// model, no network — a straight deterministic projection of the timestamped
/// facts. The heavy lifting is the pure engine in `domain/prediction_engine.dart`;
/// this provider is only the graph-store → engine glue.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock/clock.dart';
import '../../../core/graph/graph_providers.dart';
import '../domain/prediction_engine.dart';

/// The active deterministic patterns/correlations over the whole fact graph.
///
/// Recomputed whenever the graph store handle changes (e.g. after a
/// restore/wipe). Consumers `ref.watch(predictionPatternsProvider)` and render
/// the resulting [DetectedPattern]s (a small "Patrones" surface is optional).
final predictionPatternsProvider =
    FutureProvider<List<DetectedPattern>>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  final now = ref.read(clockProvider).now();
  final nodes = await store.listNodesByKind('fact');
  return detectPatterns(factSamplesFromNodes(nodes), now: now);
});
