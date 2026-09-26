// The listening level from the dictation placement, kept like the vocabulary
// one: a node of its own kind (encrypted, synced), every attempt kept, the
// latest read as the current level. "Before A1" is a real result and is kept
// as one; never measured is null, never a default level.
library;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/vocab_placement_scoring.dart';

const String kListeningKind = 'english_listening';
const String _domain = 'learning';
const int _dataVersion = 1;

/// Stored for "before A1".
const String _beforeA1 = 'none';

class ListeningResult {
  const ListeningResult({required this.level, required this.takenAt});

  /// Null: before A1.
  final CefrLevel? level;
  final DateTime takenAt;
}

/// What the screens need. An interface so they can be tested without the
/// encrypted database.
abstract interface class ListeningResults {
  Future<void> save(CefrLevel? level, {required DateTime takenAt});

  /// The latest result, or null when listening was never measured.
  Future<ListeningResult?> latest();
}

class ListeningResultRepository implements ListeningResults {
  ListeningResultRepository(this._store);

  final LocalGraphStore _store;

  @override
  Future<void> save(CefrLevel? level, {required DateTime takenAt}) =>
      _store.createNode(
        kind: kListeningKind,
        label: 'Escucha en inglés: ${level?.name.toUpperCase() ?? 'antes de A1'}',
        domain: _domain,
        occurredAt: takenAt,
        data: {
          'source': kListeningKind,
          'version': _dataVersion,
          'level': level?.name ?? _beforeA1,
          'takenAt': takenAt.toUtc().toIso8601String(),
        },
      );

  @override
  Future<ListeningResult?> latest() async {
    final all = [
      for (final node in await _store.listNodesByKind(kListeningKind))
        ?_fromNode(node),
    ]..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return all.isEmpty ? null : all.first;
  }
}

ListeningResult? _fromNode(GraphNodeRecord node) {
  final data = node.data;
  if (data['version'] != _dataVersion) return null;
  final takenAt = DateTime.tryParse('${data['takenAt']}');
  final raw = data['level'];
  if (takenAt == null || raw is! String) return null;
  if (raw == _beforeA1) return ListeningResult(level: null, takenAt: takenAt);
  final level = CefrLevel.values.asNameMap()[raw];
  return level == null ? null : ListeningResult(level: level, takenAt: takenAt);
}
