/// The bridge between what the user WROTE DOWN and the relationship logic that
/// has, until now, had nothing to read.
///
/// The birthday and contact-nudge rules were built and tested as pure
/// functions, but nothing called them: the app could store a person and then
/// did nothing with them. This turns the local `person` and `interaction`
/// entries into the [TrackedPerson] list those rules expect, so what the user
/// records finally comes back to them.
///
/// FAMILY IS DERIVED, NEVER ASKED FOR TWICE. A person's `relation` is free
/// text, and people write it the way they say it: "hija de Juan". When the tail
/// of that phrase names someone the user also recorded, the two are linked —
/// so "Sofía cumple 7" can surface as a reason to write to JUAN, which is the
/// whole point. No second form, no relationship picker: the sentence already
/// carried the link.
///
/// PURE and clock-injected — nothing here reads [DateTime.now].
library;

import '../../domains/domain/local_domain_entry.dart';
import 'birthdays.dart';
import 'contact_nudge.dart';

/// What the Relaciones screen needs to show, in one pass over the entries.
class RelationshipReminders {
  const RelationshipReminders({required this.birthdays, required this.due});

  /// Birthdays close enough to be worth mentioning, soonest first.
  final List<UpcomingBirthday> birthdays;

  /// People whose chosen cadence has elapsed, most overdue first.
  final List<ContactDue> due;

  bool get isEmpty => birthdays.isEmpty && due.isEmpty;
}

/// How far ahead the screen looks for birthdays.
///
/// Wider than the nudge's own context window: as a standalone list this is
/// something the user reads on purpose, so a month of warning is useful rather
/// than noisy. The nudge stays narrow, because that one interrupts.
const int kBirthdayHorizonDays = 30;

/// Builds the reminders from raw local entries.
RelationshipReminders relationshipReminders(
  Iterable<LocalDomainEntry> entries, {
  required DateTime now,
}) {
  final people = trackedPeopleFrom(entries);
  return RelationshipReminders(
    birthdays: upcomingBirthdays(
      [
        for (final p in people)
          if (p.birthDate != null)
            PersonBirthday(name: p.name, birthDate: p.birthDate!, relation: p.relation),
      ],
      today: now,
      withinDays: kBirthdayHorizonDays,
    ),
    due: contactsDue(people, now: now),
  );
}

/// The people the user has recorded, with their families linked and their last
/// contact derived from the interaction log.
List<TrackedPerson> trackedPeopleFrom(Iterable<LocalDomainEntry> entries) {
  final persons = <_Person>[];
  final lastContact = <String, DateTime>{};

  for (final entry in entries) {
    switch (entry.type) {
      case 'person':
        final name = _string(entry.data['name']);
        if (name.isEmpty) continue;
        persons.add(_Person(
          name: name,
          knownSince: entry.timestamp.toLocal(),
          relation: _nullable(entry.data['relation']),
          birthDate: _date(entry.data['birth_date']),
          contactEveryDays: _positiveInt(entry.data['contact_every_days']),
        ));
      case 'interaction':
        final who = _key(_string(entry.data['person']));
        if (who.isEmpty) continue;
        final at = entry.timestamp.toLocal();
        // An interaction resets the clock; only the most recent one matters.
        final known = lastContact[who];
        if (known == null || at.isAfter(known)) lastContact[who] = at;
    }
  }

  // A person recorded twice (edited, re-added) should not appear twice; the
  // first-seen record wins, since [LocalDomainRepository.list] returns newest
  // first and the newest is the one the user last meant.
  final byKey = <String, _Person>{};
  for (final p in persons) {
    byKey.putIfAbsent(_key(p.name), () => p);
  }

  return [
    for (final p in byKey.values)
      TrackedPerson(
        name: p.name,
        knownSince: p.knownSince,
        relation: p.relation,
        birthDate: p.birthDate,
        contactEveryDays: p.contactEveryDays,
        lastContact: lastContact[_key(p.name)],
        family: _familyOf(p, byKey),
      ),
  ];
}

/// The people whose `relation` points AT [owner] — "hija de Juan" belongs to
/// Juan's picture, and their birthdays are usually the better reason to write.
List<TrackedPerson> _familyOf(_Person owner, Map<String, _Person> byKey) {
  final ownerKey = _key(owner.name);
  final out = <TrackedPerson>[];
  for (final other in byKey.values) {
    if (_key(other.name) == ownerKey) continue;
    if (_relationTarget(other.relation) != ownerKey) continue;
    out.add(TrackedPerson(
      name: other.name,
      knownSince: other.knownSince,
      relation: other.relation,
      birthDate: other.birthDate,
      // Family members are surfaced through their person, never nudged about
      // on their own cadence from here.
      contactEveryDays: null,
    ));
  }
  return out;
}

/// The name a relation phrase points at: "hija de Juan" → juan. Null when the
/// phrase names no one ("amigo", "vecina").
String? _relationTarget(String? relation) {
  if (relation == null) return null;
  final match = RegExp(r'\bde\s+(.+)$', caseSensitive: false).firstMatch(relation.trim());
  if (match == null) return null;
  final target = _key(match.group(1) ?? '');
  return target.isEmpty ? null : target;
}

/// Case- and accent-insensitive identity for a person's name, so "Sofía" and
/// "sofia" are the same human.
String _key(String name) {
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

String _string(Object? v) => (v as String?)?.trim() ?? '';

String? _nullable(Object? v) {
  final s = _string(v);
  return s.isEmpty ? null : s;
}

/// Accepts the shapes a stored date arrives in: the plain `YYYY-MM-DD` a
/// date-only field writes, or an ISO instant from an older entry.
DateTime? _date(Object? v) {
  final s = _string(v);
  if (s.isEmpty) return null;
  final parsed = DateTime.tryParse(s);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

int? _positiveInt(Object? v) {
  final n = v is int ? v : int.tryParse(_string(v));
  return (n != null && n > 0) ? n : null;
}

class _Person {
  const _Person({
    required this.name,
    required this.knownSince,
    this.relation,
    this.birthDate,
    this.contactEveryDays,
  });

  final String name;
  final DateTime knownSince;
  final String? relation;
  final DateTime? birthDate;
  final int? contactEveryDays;
}
