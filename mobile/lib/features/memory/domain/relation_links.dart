/// Structured multi-edge relation links (relationships-robustness, Slice 3).
///
/// Today, a person's `relation` is a single free-text field: "hija de Juan".
/// That names ONE role and silently loses any other ("hija de Juan" AND
/// "amiga de Ana"). This introduces a `(kind, target person_id)` EDGE model —
/// many per person, append-only (a second role never overwrites the first) —
/// plus the resolution of a free-text phrase to a `person_id`, which is
/// precision-first: an exact one-match resolves, but zero or ambiguous
/// matches keep the written label AND show an explicit "unlinked" state.
/// Ambiguity resolving to nothing is the correct output far more often than a
/// guess would be — a wrong link is a silent lie, no link is a visible
/// absence.
///
/// PURE — no I/O. The repository wires this to the graph store
/// (`kind:'person_link'` nodes) in a separate file.
library;

import 'person_identity.dart' show PersonIdentity, foldPersonName;

/// One stored `(kind, target person_id)` edge, recorded from [fromPersonId]'s
/// point of view. Append-only: recording a second [linkKind] between the
/// same two people creates a SECOND [RelationLink], never overwrites this one
/// — a person can be both "jefe" and, later, "amigo" of the same colleague.
class RelationLink {
  const RelationLink({
    required this.linkId,
    required this.fromPersonId,
    required this.linkKind,
    required this.toPersonId,
    this.label,
  });

  /// Stable id of the stored `person_link` node (for append-only writes and
  /// future removal, never mutation).
  final String linkId;

  final String fromPersonId;

  /// The relation AS RECORDED ("hija", "jefe", "amiga") — free text, not a
  /// closed enum, so it stays whatever the user actually wrote.
  final String linkKind;

  final String toPersonId;

  /// The original free-text phrase the link was extracted from, when known
  /// ("hija de Juan"), kept for display even though the edge is now
  /// structured.
  final String? label;
}

/// Which side of a [RelationLink] a [LinkedPerson] view was derived from.
enum RelationLinkDirection {
  /// [LinkedPerson] was built from the recording ([RelationLink.fromPersonId])
  /// side — the kind reads exactly as stored ("hija").
  stored,

  /// [LinkedPerson] was built from the TARGET ([RelationLink.toPersonId])
  /// side, derived at read time. The kind is shown AS STORED, not inverted —
  /// no "padre"-from-"hija" vocabulary is invented; a caller renders this
  /// direction however it chooses (e.g. "hija de" prefixed differently),
  /// but nothing here guesses the inverse word.
  reciprocal,
}

/// One person browsable from [personId]'s relations page: who they're linked
/// to, and from which side the edge was recorded.
class LinkedPerson {
  const LinkedPerson({
    required this.otherPersonId,
    required this.linkKind,
    required this.direction,
    this.label,
  });

  final String otherPersonId;
  final String linkKind;
  final RelationLinkDirection direction;
  final String? label;
}

/// Every link touching [personId], from EITHER stored direction — the only
/// accessor a caller should use to browse relations. Reciprocity is derived
/// HERE, at every read, over whatever edges are currently stored: nothing is
/// ever written for the reverse direction, so it can never drift from the
/// edges that ARE stored.
///
/// Multi-edge: a person with several stored links (in either direction) sees
/// ALL of them, never just the first recorded.
List<LinkedPerson> linksBothWays(List<RelationLink> links, String personId) {
  final out = <LinkedPerson>[];
  for (final link in links) {
    if (link.fromPersonId == personId) {
      out.add(LinkedPerson(
        otherPersonId: link.toPersonId,
        linkKind: link.linkKind,
        direction: RelationLinkDirection.stored,
        label: link.label,
      ));
    } else if (link.toPersonId == personId) {
      out.add(LinkedPerson(
        otherPersonId: link.fromPersonId,
        linkKind: link.linkKind,
        direction: RelationLinkDirection.reciprocal,
        label: link.label,
      ));
    }
  }
  return out;
}

/// Outcome of resolving a free-text relation phrase to a `person_id`.
enum RelationResolution {
  /// Exactly one candidate matched — [RelationTargetResolution.targetPersonId]
  /// is set.
  resolved,

  /// The phrase names no one at all ("amiga", "vecino") — there was nothing
  /// to resolve, so this is NOT the "unlinked" state; it's simply untargeted.
  noTarget,

  /// The phrase names someone, but nobody recorded matches — the label is
  /// kept, and the UI must show this loudly as "unlinked". Never guessed.
  unlinkedNoMatch,

  /// The phrase names someone, but MORE THAN ONE recorded person matches —
  /// same "unlinked" treatment. Never auto-selects.
  unlinkedAmbiguous,
}

/// The result of [resolveRelationTarget]: either a resolved `person_id`, or
/// one of the two "unlinked" reasons — the free-text label is never dropped
/// either way, only whether it resolved to a specific person_id changes.
class RelationTargetResolution {
  const RelationTargetResolution({required this.status, this.targetPersonId});

  final RelationResolution status;
  final String? targetPersonId;

  /// True for either "unlinked" reason — the phrase named someone but
  /// resolution failed (zero or ambiguous matches). False for [noTarget]
  /// (nothing was named) and for [resolved].
  bool get isUnlinked =>
      status == RelationResolution.unlinkedNoMatch || status == RelationResolution.unlinkedAmbiguous;
}

/// The name a relation phrase points at ("hija de Juan" → "juan"), folded via
/// [foldPersonName]. Null when the phrase names no one.
///
/// Same rule characterized against `relationship_reminders.dart`'s private
/// `_relationTarget` in Slice 1 — duplicated here on purpose rather than
/// exported from that file, since this module must stay independent of the
/// (unrelated) Slice 4 reminder-wiring work.
String? _relationTargetKey(String? relation) {
  if (relation == null) return null;
  final match = RegExp(r'\bde\s+(.+)$', caseSensitive: false).firstMatch(relation.trim());
  if (match == null) return null;
  final target = foldPersonName(match.group(1) ?? '');
  return target.isEmpty ? null : target;
}

/// Whether two folded keys refer to the same human: exact match, or one is a
/// whole-leading-word prefix of the other ("juan" of "juan perez"), never a
/// partial-word match ("juan" is not a prefix-match of "juana").
bool _sameHumanKey(String a, String b) => a == b || a.startsWith('$b ') || b.startsWith('$a ');

/// Resolves a free-text [relation] phrase against the recorded [candidates],
/// excluding [excludePersonId] (a person never resolves to themselves).
///
/// Precision over reach: an exact ONE match resolves; zero or more-than-one
/// matches return an explicit "unlinked" status instead of guessing.
RelationTargetResolution resolveRelationTarget(
  String? relation,
  List<PersonIdentity> candidates, {
  required String excludePersonId,
}) {
  final target = _relationTargetKey(relation);
  if (target == null) {
    return const RelationTargetResolution(status: RelationResolution.noTarget);
  }

  final matches = <PersonIdentity>[
    for (final candidate in candidates)
      if (candidate.personId != excludePersonId && candidate.foldedKeys.any((key) => _sameHumanKey(key, target)))
        candidate,
  ];

  if (matches.length == 1) {
    return RelationTargetResolution(status: RelationResolution.resolved, targetPersonId: matches.single.personId);
  }
  if (matches.isEmpty) {
    return const RelationTargetResolution(status: RelationResolution.unlinkedNoMatch);
  }
  return const RelationTargetResolution(status: RelationResolution.unlinkedAmbiguous);
}
