/// A read-only directory that resolves a fact's family-subject relation label
/// (e.g. "esposa", "papá") to the DISPLAY name of the person it belongs to
/// (e.g. "Celia", "papá"), using the on-device person hub nodes.
///
/// The person hub (see [MemoryWriter]) stores each relation person as a
/// `kind:'person'` node whose `data.relation` is the canonical relation label
/// and whose `label` is the person's real name once known (else the relation
/// word). The user themself is the hub node marked `data.role == 'user'`.
///
/// Used by the unified "Mi vida" view and the daily digest to group entries
/// per person (me / Celia / papá) without duplicating the resolution logic.
library;

import '../../../core/graph/graph_records.dart';
import 'subject.dart' show foldAccents, canonRelation;

/// Stable grouping key for the user themself (unmarked entries).
const String kSelfPersonKey = '@self';

class PersonDirectory {
  const PersonDirectory(this._byRelation, {this.selfLabel = 'Yo'});

  /// Folded canonical relation label → person display name.
  final Map<String, String> _byRelation;

  /// Display label for the user's own (unmarked) entries.
  final String selfLabel;

  /// Build the directory from the `kind:'person'` nodes of the graph store.
  factory PersonDirectory.fromNodes(
    List<GraphNodeRecord> personNodes, {
    String selfLabel = 'Yo',
  }) {
    final map = <String, String>{};
    for (final p in personNodes) {
      if (p.data['role'] == 'user') continue; // the hub is the self, not a relation
      final rel = p.data['relation'];
      if (rel is! String || rel.trim().isEmpty) continue;
      final folded = _foldRelation(rel);
      final name = p.label.trim();
      map[folded] = name.isEmpty ? rel.trim() : name;
    }
    return PersonDirectory(map, selfLabel: selfLabel);
  }

  /// Fold + canonicalize a raw relation word so "papa"/"padre"/"papá" collapse
  /// to one key, matching the person node's stored canonical relation.
  static String _foldRelation(String rel) {
    final folded = foldAccents(rel.trim().toLowerCase());
    final canon = canonRelation(folded);
    return canon != null ? foldAccents(canon.toLowerCase()) : folded;
  }

  /// Display name for a fact whose `data.subject` is [subject] (a relation
  /// label), or the [selfLabel] when the entry is unmarked (the user's own).
  String displayFor(String? subject) {
    if (subject == null || subject.trim().isEmpty) return selfLabel;
    return _byRelation[_foldRelation(subject)] ?? subject.trim();
  }

  /// Stable grouping key so entries for the same person cluster together even
  /// before that person has been named.
  String keyFor(String? subject) {
    if (subject == null || subject.trim().isEmpty) return kSelfPersonKey;
    return _foldRelation(subject);
  }
}
