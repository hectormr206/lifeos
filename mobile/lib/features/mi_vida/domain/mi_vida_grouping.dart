/// Pure grouping for the unified "Mi vida" view: ALL saved domain entries
/// (across the 7 domains) grouped by domain (in [domainDescriptors] order) and
/// then by PERSON (me / Celia / papá …), newest first.
///
/// Reuses the digest's [DigestDomainSection] / [DigestPersonGroup] shape (a
/// generic domain → person → entries tree) so the two views stay consistent.
/// Unlike the daily digest, this does NOT filter to today — it is the full
/// history.
library;

import '../../daily_digest/domain/daily_digest.dart';
import '../../domains/domain/domain_descriptor.dart';
import '../../domains/domain/local_domain_entry.dart';
import '../../memory/domain/person_directory.dart';

/// Group [entriesByDomain] (keyed by `DomainDescriptor.key`) by domain + person.
/// Entries are assumed already newest-first (as `LocalDomainRepository.list`
/// returns them); empty domains are skipped.
List<DigestDomainSection> groupByDomainAndPerson(
  Map<String, List<LocalDomainEntry>> entriesByDomain, {
  required PersonDirectory directory,
}) {
  final sections = <DigestDomainSection>[];
  for (final descriptor in domainDescriptors) {
    final entries = entriesByDomain[descriptor.key] ?? const <LocalDomainEntry>[];
    if (entries.isEmpty) continue;

    final order = <String>[];
    final byPerson = <String, List<LocalDomainEntry>>{};
    for (final entry in entries) {
      final subject = entry.data['subject'] as String?;
      final key = directory.keyFor(subject);
      (byPerson[key] ??= <LocalDomainEntry>[]).add(entry);
      if (!order.contains(key)) order.add(key);
    }

    final groups = <DigestPersonGroup>[];
    for (final key in order) {
      final personEntries = byPerson[key]!;
      final subject = personEntries.first.data['subject'] as String?;
      groups.add(DigestPersonGroup(
        personKey: key,
        personLabel: directory.displayFor(subject),
        entries: personEntries,
      ));
    }

    sections.add(DigestDomainSection(
      domainKey: descriptor.key,
      domainTitle: descriptor.title,
      people: groups,
    ));
  }
  return sections;
}
