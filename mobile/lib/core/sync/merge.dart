// The merge rule, Dart side. A line-for-line mirror of `decide()` in
// `axi/src/axi/sync/merge.py`.
//
// Both languages are asserted against `shared/sync-test-vectors/merge_cases.json`,
// which states the rules ONCE as data. Two hand-written suites that happen to
// agree today is not parity; a shared fixture both must satisfy is. When these
// two disagree, both suites go red — instead of an envelope resolving one way
// on the laptop and the other way on the phone, with the user's memory as the
// casualty.
//
// THE RULES, in order:
//   1. Never seen locally        -> insert.
//   2. Higher `lamport` wins.
//   3. Equal `lamport`           -> lexicographically greater `originNode`.
//   4. A DELETE dominates, even against a higher `lamport`.
//   5. The loser is preserved, never destroyed.
//
// Rule 3 is arbitrary; that it is DETERMINISTIC is not. Both devices must
// reach the same answer without talking, or they diverge permanently and
// neither can tell.
//
// Rule 4 is the only deviation from pure last-writer-wins. You delete a note on
// the laptop; the phone is offline and you edit it there afterwards. Pure LWW
// gives the edit the higher clock and the note comes BACK. In an app holding a
// person's whole life, handing back something they believed erased is a privacy
// failure, not a merge outcome. Rule 5 is what makes rule 4 safe.

enum MergeOutcome { inserted, updated, rejected }

/// One side of a merge, as it arrives or as it already sits locally.
class MergeRevision {
  const MergeRevision({
    required this.lamport,
    required this.originNode,
    required this.deleted,
  });

  final int lamport;
  final String originNode;
  final bool deleted;
}

/// Rules 2 and 3 as ONE comparison of an ordered pair.
///
/// Deliberately not `if (lamport >) ... else if (lamport ==) ...`: branching
/// leaves a path that reaches a decision without ever consulting the origin,
/// which is exactly the equal-clock case that then resolves by arrival order.
/// Comparing the pair makes the tiebreak impossible to forget.
bool _wins(MergeRevision incoming, MergeRevision local) {
  if (incoming.lamport != local.lamport) {
    return incoming.lamport > local.lamport;
  }
  return incoming.originNode.compareTo(local.originNode) > 0;
}

/// THE rule, pure: no database, no I/O, nothing to mock.
///
/// Rule 4 is checked FIRST, before any clock comparison. Inside the comparison
/// it would be one refactor of the condition order away from silently losing
/// its effect — and nothing about the app would look different afterwards.
MergeOutcome decideMerge({
  required MergeRevision? local,
  required MergeRevision incoming,
}) {
  if (local == null) return MergeOutcome.inserted;

  // RULE 4 — a live incoming revision never beats a local tombstone, however
  // high its Lamport value.
  if (local.deleted && !incoming.deleted) return MergeOutcome.rejected;

  return _wins(incoming, local) ? MergeOutcome.updated : MergeOutcome.rejected;
}

/// Whether this pair of revisions is a genuine disagreement worth showing the
/// user, or one device's own linear history.
///
/// A device overwriting its own earlier row is not a conflict. Recording those
/// would bury the real ones under noise, and a conflict history is only useful
/// if everything in it is genuinely two devices disagreeing.
bool isConflict({required MergeRevision? local, required MergeRevision incoming}) {
  if (local == null) return false;
  return local.originNode != incoming.originNode;
}
