// Every vocabulary placement the learner takes, kept on their own devices.
//
// A placement is a graph node of its own kind, NOT a `fact`: it is a
// measurement, not a memory. The Cerebro loads only facts, people, events and
// entities, so it never draws these, and the cleanup that runs from there
// never judges them. They go in the graph anyway, and not in a file of their
// own, because the graph already encrypts, syncs and resolves conflicts. That
// is what lets the laptop and the phone agree on the learner's level without
// a second mechanism that would have to earn each of those properties again.
//
// Every attempt is kept, including unreliable ones: the history should be the
// truth. What counts as the CURRENT level is the latest reliable one.
library;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/vocab_placement_scoring.dart';

const String kEnglishPlacementKind = 'english_placement';

/// The product domain these nodes belong to.
const String kEnglishPlacementDomain = 'learning';

/// Shape of `data`. Bump it when a field changes meaning; a node with another
/// version is skipped rather than misread.
const int kEnglishPlacementDataVersion = 1;

class PlacementRecord {
  const PlacementRecord({required this.takenAt, required this.result});

  final DateTime takenAt;
  final VocabPlacementResult result;
}

/// What the placement screen needs from storage, and nothing more, so the
/// screen can be tested without opening the encrypted database.
abstract interface class PlacementHistory {
  Future<void> save(VocabPlacementResult result, {required DateTime takenAt});

  Future<PlacementRecord?> latestReliable();
}

class EnglishPlacementRepository implements PlacementHistory {
  EnglishPlacementRepository(this._store);

  final LocalGraphStore _store;

  @override
  Future<void> save(
    VocabPlacementResult result, {
    required DateTime takenAt,
  }) async {
    await _store.createNode(
      kind: kEnglishPlacementKind,
      label: 'Vocabulario en inglés: ${result.cefr.name.toUpperCase()} '
          '(${result.estimatedWords} palabras)',
      domain: kEnglishPlacementDomain,
      occurredAt: takenAt,
      data: {
        // Written by a person taking a test, not invented by a model: any
        // cleanup that reads `source` leaves it alone.
        'source': kEnglishPlacementKind,
        'version': kEnglishPlacementDataVersion,
        'takenAt': takenAt.toUtc().toIso8601String(),
        'cefr': result.cefr.name,
        'estimatedWords': result.estimatedWords,
        'xlexScore': result.xlexScore,
        'reliable': result.reliable,
        'falseAlarmRate': result.falseAlarmRate,
        'knownByBand': result.knownByBand,
      },
    );
  }

  /// Every readable placement, newest first.
  Future<List<PlacementRecord>> history() async {
    final nodes = await _store.listNodesByKind(kEnglishPlacementKind);
    return nodes.map(_fromNode).whereType<PlacementRecord>().toList()
      ..sort((a, b) => b.takenAt.compareTo(a.takenAt));
  }

  /// The learner's current level, or null before any reliable placement.
  /// Never a default: "no data" must not read as "A1".
  @override
  Future<PlacementRecord?> latestReliable() async {
    for (final record in await history()) {
      if (record.result.reliable) return record;
    }
    return null;
  }
}

PlacementRecord? _fromNode(GraphNodeRecord node) {
  final data = node.data;
  if (data['version'] != kEnglishPlacementDataVersion) return null;
  final takenAt = DateTime.tryParse('${data['takenAt']}');
  final cefr = CefrLevel.values.asNameMap()[data['cefr']];
  final words = data['estimatedWords'];
  final xlex = data['xlexScore'];
  final reliable = data['reliable'];
  final falseAlarms = data['falseAlarmRate'];
  final bands = data['knownByBand'];
  if (takenAt == null ||
      cefr == null ||
      words is! int ||
      xlex is! int ||
      reliable is! bool ||
      falseAlarms is! num ||
      bands is! List ||
      bands.any((rate) => rate is! num)) {
    return null;
  }
  return PlacementRecord(
    takenAt: takenAt,
    result: VocabPlacementResult(
      knownByBand: [for (final rate in bands) (rate as num).toDouble()],
      falseAlarmRate: falseAlarms.toDouble(),
      estimatedWords: words,
      xlexScore: xlex,
      cefr: cefr,
      reliable: reliable,
    ),
  );
}
