/// Stable person identity (relationships-robustness, Slice 2).
///
/// Today, "who this is" is a folded name string recomputed on every read —
/// rename someone and every link that pointed at their old spelling silently
/// stops resolving. This introduces a stable ULID `person_id` that survives a
/// rename, plus the pure grouping logic the one-time additive migration uses
/// to mint exactly one identity per person already recorded.
///
/// PURE — no I/O, no [DateTime.now], no unseeded randomness. The repository
/// wires this to the graph store (`kind:'person'` nodes) in a separate file.
library;

import 'dart:math' as math;

/// Case- and accent-insensitive identity key for a person's name, so "Sofía"
/// and "sofia" fold to the same key.
///
/// This is the EXACT rule characterized in
/// `person_identity_characterization_test.dart` against
/// `relationship_reminders.dart`'s private `_key()` — kept here as the single
/// source of truth for the identity layer; if the two ever need to diverge
/// (e.g. a future per-runtime folding rule), that is a decision to make out
/// loud, not a drift to discover later.
String foldPersonName(String name) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñ';
  const to = 'aaaaeeeeiiiioooouuuun';
  final lower = name.trim().toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  return buffer.toString();
}

/// A stable person identity: a `person_id` that survives a rename, plus every
/// folded key that has ever resolved to it (a rename appends, never replaces,
/// so a pre-rename mention still finds this person).
class PersonIdentity {
  const PersonIdentity({
    required this.personId,
    required this.canonicalName,
    required this.foldedKeys,
    this.unnamed = false,
    this.deceased = false,
  });

  /// The stable ULID. Never changes for this person's lifetime.
  final String personId;

  /// The name as most recently given by the user.
  final String canonicalName;

  /// Every folded key that resolves to this person (today's fold rule,
  /// characterized in Slice 1).
  final List<String> foldedKeys;

  /// True for the minted current-partner placeholder before the user has
  /// named them (Slice 5). Readers that surface a name skip these.
  final bool unnamed;

  /// True once the person is marked deceased/inactive (Slice 6). Reminder
  /// pipelines skip these.
  final bool deceased;

  @override
  String toString() => 'PersonIdentity($personId, $canonicalName)';
}

/// A single raw name, as recorded on one existing `person` fact entry, ready
/// to be folded into the migration's identity groups.
class NameOccurrence {
  const NameOccurrence({required this.name, required this.recordedAt});

  final String name;
  final DateTime recordedAt;
}

/// Groups raw name occurrences by TODAY's exact folded-name rule (locked in
/// Slice 1) into one [PersonIdentity] per group, minting each id via
/// [mintId] — called exactly once per distinct folded key, in encounter
/// order, so the migration is reproducible given a deterministic [mintId].
///
/// The canonical name is the MOST RECENTLY RECORDED spelling, mirroring the
/// per-field merge rule `relationship_reminders.dart` already applies ("the
/// name as most recently written wins").
///
/// Pure — no I/O. The caller (repository) reads the existing entries, calls
/// this, and persists the result; nothing here touches a database.
List<PersonIdentity> groupForMigration(
  List<NameOccurrence> occurrences, {
  required String Function() mintId,
}) {
  final byKey = <String, List<NameOccurrence>>{};
  final order = <String>[];
  for (final o in occurrences) {
    final name = o.name.trim();
    if (name.isEmpty) continue;
    final key = foldPersonName(name);
    if (!byKey.containsKey(key)) order.add(key);
    byKey.putIfAbsent(key, () => []).add(o);
  }

  return [
    for (final key in order)
      _identityFor(key, byKey[key]!, mintId()),
  ];
}

PersonIdentity _identityFor(String key, List<NameOccurrence> group, String personId) {
  final newest = group.reduce((a, b) => b.recordedAt.isAfter(a.recordedAt) ? b : a);
  return PersonIdentity(
    personId: personId,
    canonicalName: newest.name.trim(),
    foldedKeys: [key],
  );
}

/// A rename: keeps [PersonIdentity.personId] (the whole point of the
/// identity layer surviving a typo fix) and appends the new folded key
/// instead of replacing the old one, so links made before the rename still
/// resolve. Naming an [PersonIdentity.unnamed] placeholder (Slice 5's current
/// partner) for the first time is just a rename that also clears the flag.
PersonIdentity renamed(PersonIdentity identity, String newName) {
  final trimmed = newName.trim();
  final key = foldPersonName(trimmed);
  final keys = identity.foldedKeys.contains(key) ? identity.foldedKeys : [...identity.foldedKeys, key];
  return PersonIdentity(
    personId: identity.personId,
    canonicalName: trimmed,
    foldedKeys: keys,
    unnamed: false,
    deceased: identity.deceased,
  );
}

/// Whether [identity]'s folded name matches a DIFFERENT identity's folded
/// name in [others]. Detection only — per the proposal's binding answer,
/// resolution (merge/split) is explicitly out of scope; this only decides
/// whether to show the non-blocking "same name detected" indicator.
bool foldedKeyCollidesWithOther(PersonIdentity identity, List<PersonIdentity> others) {
  for (final other in others) {
    if (other.personId == identity.personId) continue;
    if (identity.foldedKeys.any(other.foldedKeys.contains)) return true;
  }
  return false;
}

// ─── ULID minting ───────────────────────────────────────────────────────────

const String _crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// A source of random bytes for ULID minting, injected so tests are
/// deterministic (ADR-4 governs clock/day-count math; entropy is not that,
/// but a mintable id still needs to be reproducible in a test).
abstract class RandomBytesSource {
  int nextByte();
}

/// Mints a 26-character Crockford-base32 ULID: a 48-bit millisecond
/// timestamp (from [now], so two ids minted in the same process run at
/// different logical times still sort correctly) followed by 80 bits of
/// randomness (from [random], defaulting to a fresh unseeded source per
/// call).
///
/// Lexicographic order follows creation order because the timestamp bits
/// come first — useful for `ORDER BY person_id` style debugging, though
/// nothing in this feature relies on that ordering for correctness.
String mintUlid({
  DateTime Function() now = DateTime.now,
  RandomBytesSource? random,
}) {
  final source = random ?? _SecureRandomBytesSource();
  final ms = now().toUtc().millisecondsSinceEpoch;
  var bits = BigInt.from(ms);
  for (var i = 0; i < 10; i++) {
    bits = (bits << 8) | BigInt.from(source.nextByte() & 0xff);
  }
  final chars = List<String>.filled(26, '0');
  var remaining = bits;
  for (var i = 25; i >= 0; i--) {
    chars[i] = _crockfordAlphabet[(remaining & BigInt.from(31)).toInt()];
    remaining >>= 5;
  }
  return chars.join();
}

class _SecureRandomBytesSource implements RandomBytesSource {
  final math.Random _rnd = math.Random.secure();

  @override
  int nextByte() => _rnd.nextInt(256);
}
