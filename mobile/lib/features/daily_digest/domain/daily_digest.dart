import 'dart:convert';

import '../../domains/domain/local_domain_entry.dart';

/// One person's entries within a domain section of the daily digest.
class DigestPersonGroup {
  const DigestPersonGroup({
    required this.personKey,
    required this.personLabel,
    required this.entries,
  });

  /// Stable grouping key (`@self` for the user, folded relation otherwise).
  final String personKey;

  /// Display name shown in the digest ("Yo", "Celia", "papá").
  final String personLabel;

  /// This person's entries in the domain, newest first.
  final List<LocalDomainEntry> entries;
}

/// One domain's activity for today, sub-grouped by person.
class DigestDomainSection {
  const DigestDomainSection({
    required this.domainKey,
    required this.domainTitle,
    required this.people,
  });

  final String domainKey;
  final String domainTitle;
  final List<DigestPersonGroup> people;

  int get count => people.fold(0, (sum, g) => sum + g.entries.length);
}

/// The deterministic aggregation over TODAY's local data — the FACTUAL content
/// of the digest. Assembled with exact per-record timestamps; never invented.
class DailyDigestData {
  const DailyDigestData({required this.generatedAt, required this.sections});

  final DateTime generatedAt;
  final List<DigestDomainSection> sections;

  int get totalEntries => sections.fold(0, (sum, s) => sum + s.count);

  bool get isEmpty => totalEntries == 0;
}

/// A generated + persisted daily digest, ready to render and to post as a
/// notification body.
///
/// [deterministicText] is the exact aggregated facts (respects
/// never-corrupt-user-data: pure aggregation). [wrapUp] is the optional
/// on-device model's short natural-language narration OVER those facts — it may
/// be empty when the model is unavailable or degenerated, and the digest is
/// still fully valid without it.
class DailyDigest {
  const DailyDigest({
    required this.generatedAt,
    required this.deterministicText,
    required this.wrapUp,
    required this.entriesCount,
  });

  final DateTime generatedAt;
  final String deterministicText;
  final String wrapUp;
  final int entriesCount;

  bool get isEmpty => entriesCount == 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'deterministicText': deterministicText,
        'wrapUp': wrapUp,
        'entriesCount': entriesCount,
      };

  static DailyDigest fromJson(Map<String, Object?> json) => DailyDigest(
        generatedAt:
            DateTime.tryParse('${json['generatedAt']}')?.toLocal() ?? DateTime.now(),
        deterministicText: (json['deterministicText'] as String?) ?? '',
        wrapUp: (json['wrapUp'] as String?) ?? '',
        entriesCount: (json['entriesCount'] as num?)?.toInt() ?? 0,
      );

  String encode() => jsonEncode(toJson());

  static DailyDigest? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return DailyDigest.fromJson(Map<String, Object?>.from(decoded));
      }
    } catch (_) {
      // Corrupt cache must never crash hydration — treat as "no digest yet".
    }
    return null;
  }
}
