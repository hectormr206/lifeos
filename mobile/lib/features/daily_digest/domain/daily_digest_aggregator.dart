/// Pure, deterministic aggregation for the on-device daily digest.
///
/// Ported in spirit from the laptop `lifeos/src/lifeos/insights/digest.py`
/// (deterministic aggregation over timestamped domain rows), but running over
/// the on-device [LocalDomainRepository] data. It is DETERMINISTIC and pure:
/// no model, no I/O — so it is trivially unit-testable and can never invent
/// data (never-corrupt-user-data).
///
/// It groups TODAY's entries (device-local calendar day of [now]) by domain
/// (in [domainDescriptors] order) and then by PERSON (resolved via
/// [PersonDirectory] from the structured-capture person hub). Every entry keeps
/// its exact per-record timestamp; entries from any other day are excluded.
library;

import 'package:timezone/timezone.dart' as tz;

import '../../domains/domain/domain_descriptor.dart';
import '../../domains/domain/local_domain_entry.dart';
import '../../memory/domain/person_directory.dart';
import 'daily_digest.dart';

/// Aggregate today's entries (grouped by domain + person) from the per-domain
/// entry lists. [entriesByDomain] is keyed by `DomainDescriptor.key`.
///
/// TIMEZONE: [location] selects the zone that defines "today" (the local
/// calendar day). `null` (AUTOMATIC) uses device-local time (unchanged); a
/// manual override uses that zone, so an entry near midnight lands in the right
/// local day for the chosen zone.
DailyDigestData aggregateDailyDigest(
  Map<String, List<LocalDomainEntry>> entriesByDomain, {
  required DateTime now,
  required PersonDirectory directory,
  tz.Location? location,
}) {
  final today = _localDay(now, location);
  final sections = <DigestDomainSection>[];

  for (final descriptor in domainDescriptors) {
    final all = entriesByDomain[descriptor.key] ?? const <LocalDomainEntry>[];
    // TODAY only, using the entry's EXACT timestamp in the effective zone.
    final todays = all
        .where((e) => _localDay(e.timestamp, location) == today)
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (todays.isEmpty) continue;

    // Sub-group by person, preserving first-seen order (self tends to appear
    // first because self entries dominate).
    final order = <String>[];
    final byPerson = <String, List<LocalDomainEntry>>{};
    for (final entry in todays) {
      final subject = entry.data['subject'] as String?;
      final key = directory.keyFor(subject);
      (byPerson[key] ??= <LocalDomainEntry>[]).add(entry);
      if (!order.contains(key)) order.add(key);
    }

    final groups = <DigestPersonGroup>[];
    for (final key in order) {
      final entries = byPerson[key]!;
      final subject = entries.first.data['subject'] as String?;
      groups.add(DigestPersonGroup(
        personKey: key,
        personLabel: directory.displayFor(subject),
        entries: entries,
      ));
    }

    sections.add(DigestDomainSection(
      domainKey: descriptor.key,
      domainTitle: descriptor.title,
      people: groups,
    ));
  }

  return DailyDigestData(generatedAt: now, sections: sections);
}

DateTime _localDay(DateTime t, [tz.Location? location]) {
  final local = location == null ? t.toLocal() : tz.TZDateTime.from(t, location);
  return DateTime(local.year, local.month, local.day);
}

/// Render the deterministic facts as a readable neutral-Spanish block. This is
/// the FACTUAL content (exact, aggregated) that the digest always shows and
/// that the model narration is grounded on.
///
/// TIMEZONE: [location] must be the SAME effective zone the today-window was
/// aggregated in (null = AUTOMATIC = device-local, unchanged). Rendering with
/// the device zone while the window used a manual override printed the wrong
/// date/times ("Resumen de hoy — 02/01" for entries selected for the LA day
/// 01/01) — and the model narration, grounded on this text, repeated them.
String renderDigestFacts(DailyDigestData data, {tz.Location? location}) {
  DateTime inZone(DateTime t) =>
      location == null ? t.toLocal() : tz.TZDateTime.from(t, location);
  final date = _formatDate(inZone(data.generatedAt));
  final buffer = StringBuffer('Resumen de hoy — $date\n');
  if (data.isEmpty) {
    buffer.write('\nHoy todavía no registraste nada en tus dominios.');
    return buffer.toString();
  }
  for (final section in data.sections) {
    buffer.write('\n');
    buffer.writeln('${section.domainTitle}: ${_plural(section.count, "registro", "registros")}');
    for (final group in section.people) {
      buffer.writeln('  • ${group.personLabel}: ${_plural(group.entries.length, "registro", "registros")}');
      for (final entry in group.entries) {
        buffer.writeln('    - ${entry.label} (${_formatTime(inZone(entry.timestamp))})');
      }
    }
  }
  buffer.write('\nTotal: ${_plural(data.totalEntries, "registro", "registros")} hoy.');
  return buffer.toString();
}

String _plural(int n, String one, String many) => n == 1 ? '$n $one' : '$n $many';

String _two(int n) => n.toString().padLeft(2, '0');

String _formatDate(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';

String _formatTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
