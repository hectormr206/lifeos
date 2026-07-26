import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/daily_digest.dart';
import '../domain/daily_digest_preferences.dart';

/// Encrypted persistence for the daily-digest CONTENT (the last generated
/// digest). The schedule (enabled/hour/minute) is a SETTING and stays in
/// `shared_preferences` ([SharedPrefsDailyDigestPreferences]); the digest text
/// is USER CONTENT (a model narration over the user's people, health and day)
/// and must be encrypted at rest.
abstract class DailyDigestContentStore {
  /// The last digest produced, or null if never run.
  Future<DailyDigest?> lastDigest();

  Future<void> saveLastDigest(DailyDigest digest);
}

/// [DailyDigestContentStore] backed by the SQLCipher-encrypted graph database.
///
/// WHY THE GRAPH DB (and not `flutter_secure_storage`): everything structural
/// about the user's life (graph, vectors, chat) already lives in the encrypted
/// graph DB, so a single well-known `app_state` node makes the digest inherit
/// SQLCipher encryption, the full-wipe path (the graph file deletion + key
/// rotation covers it automatically) and backups — with zero new dependencies.
/// `flutter_secure_storage` is designed for small secrets (keys, tokens); a
/// multi-KB narration does not belong in the platform keystore.
///
/// The digest lives as ONE node with a FIXED uuid ([digestNodeUuid]) and kind
/// `app_state`, upserted on every save — never a growing history.
///
/// LEGACY MIGRATION: builds before this store persisted the digest in PLAIN
/// `shared_preferences` under [SharedPrefsDailyDigestPreferences.legacyLastDigestKey].
/// On first read the plain value is imported into the encrypted node, VERIFIED
/// readable, and only then the plain key is deleted — removing the plaintext
/// copy is the point of the migration, but a failed import never loses the
/// digest (the plain key is kept and its content still returned).
class GraphDailyDigestContentStore implements DailyDigestContentStore {
  GraphDailyDigestContentStore({
    required LocalGraphStore store,
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
  }) : _store = store, // ignore: prefer_initializing_formals
       _preferences = preferences ?? SharedPreferences.getInstance,
       _now = clock ?? DateTime.now;

  final LocalGraphStore _store;
  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _now;

  /// Well-known identity of the single digest node. Not a random v4 uuid on
  /// purpose: a STABLE key is what makes save an upsert (and sync converge on
  /// one row) instead of accreting copies.
  static const String digestNodeUuid = 'app-state:daily-digest-last';
  static const String digestNodeKind = 'app_state';
  static const String digestNodeLabel = 'daily_digest_last';

  @override
  Future<DailyDigest?> lastDigest() async {
    final node = await _store.getNodeByUuid(digestNodeUuid);
    if (node != null) {
      final digest = _decodeVerified(node.data);
      if (digest != null) {
        // Encrypted copy exists and is readable — any plain leftover is a
        // stale plaintext copy (every save also clears it); purge it
        // defensively. Never purge the fallback until this check succeeds.
        await _removeLegacyPlainKey();
        return digest;
      }
    }
    return _migrateLegacyPlainDigest();
  }

  @override
  Future<void> saveLastDigest(DailyDigest digest) async {
    await _writeNode(digest);
    // The encrypted store now holds the newest digest — the plain pre-update
    // copy (if any survived) is stale sensitive plaintext; remove it.
    await _removeLegacyPlainKey();
  }

  /// One-shot import of the pre-encryption plain `shared_preferences` value:
  /// import → verify readable → ONLY THEN delete the plain key. Returns the
  /// legacy digest (even when the import failed — no loss), or null when there
  /// is nothing to migrate.
  Future<DailyDigest?> _migrateLegacyPlainDigest() async {
    String? raw;
    try {
      raw = (await _preferences()).getString(
        SharedPrefsDailyDigestPreferences.legacyLastDigestKey,
      );
    } catch (_) {
      return null; // prefs unavailable (widget test) — nothing to migrate
    }
    if (raw == null) return null;
    final digest = DailyDigest.decode(raw);
    if (digest == null) {
      // Undecodable plaintext: no readable digest to preserve, and the blob is
      // already treated as "no digest" everywhere — remove the plaintext.
      await _removeLegacyPlainKey();
      return null;
    }
    try {
      await _writeNode(digest);
      // [_writeNode] read-backs and compares the full payload before it
      // returns. Only after that proof may the plaintext fallback disappear.
      await _removeLegacyPlainKey();
    } catch (_) {
      // Import failed → the plain key is KEPT so the digest is never lost;
      // the next read retries the migration.
    }
    return digest;
  }

  Future<void> _writeNode(DailyDigest digest) async {
    final now = _now();
    final existing = await _store.getNodeByUuid(
      digestNodeUuid,
      includeDeleted: true,
    );
    // Rebuilt (not copyWith) so a tombstoned row is revived: deletedAt resets
    // to null while createdAt/lamport lineage is preserved for sync.
    await _store.upsertNode(
      GraphNodeRecord(
        uuid: digestNodeUuid,
        kind: digestNodeKind,
        label: digestNodeLabel,
        data: digest.toJson(),
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        lamport: (existing?.lamport ?? 0) + 1,
      ),
    );
    final stored = await _store.getNodeByUuid(digestNodeUuid);
    if (stored == null || !_sameDigest(_decodeVerified(stored.data), digest)) {
      throw StateError('daily digest graph write could not be verified');
    }
  }

  /// `DailyDigest.fromJson` is intentionally forgiving for rendering old or
  /// partly-corrupt data. Migration needs a stronger guarantee: deleting the
  /// only plaintext fallback is allowed only after every persisted field can
  /// be read with its expected type.
  DailyDigest? _decodeVerified(Map<String, Object?> data) {
    final generatedAt = data['generatedAt'];
    if (generatedAt is! String || DateTime.tryParse(generatedAt) == null) {
      return null;
    }
    if (data['deterministicText'] is! String ||
        data['wrapUp'] is! String ||
        data['entriesCount'] is! num) {
      return null;
    }
    return DailyDigest.fromJson(data);
  }

  bool _sameDigest(DailyDigest? left, DailyDigest right) =>
      left != null &&
      left.generatedAt.toUtc() == right.generatedAt.toUtc() &&
      left.deterministicText == right.deterministicText &&
      left.wrapUp == right.wrapUp &&
      left.entriesCount == right.entriesCount;

  Future<void> _removeLegacyPlainKey() async {
    try {
      await (await _preferences()).remove(
        SharedPrefsDailyDigestPreferences.legacyLastDigestKey,
      );
    } catch (_) {
      // Best-effort: the wipe target also purges this key defensively.
    }
  }
}
