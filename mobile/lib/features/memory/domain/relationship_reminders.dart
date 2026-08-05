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
import 'love_languages.dart';

/// What the Relaciones screen needs to show, in one pass over the entries.
class RelationshipReminders {
  const RelationshipReminders({
    required this.birthdays,
    required this.due,
    this.loveLanguages,
  });

  /// Birthdays close enough to be worth mentioning, soonest first.
  final List<UpcomingBirthday> birthdays;

  /// People whose chosen cadence has elapsed, most overdue first.
  final List<ContactDue> due;

  /// The couple mismatch, when the recorded acts show one — usually null.
  ///
  /// Silence is the correct answer far more often than not: on thin evidence,
  /// on one-sided evidence, and when both already speak the same language, the
  /// rule says nothing rather than manufacture a finding about someone's
  /// marriage.
  final LoveLanguageObservation? loveLanguages;

  bool get isEmpty => birthdays.isEmpty && due.isEmpty && loveLanguages == null;
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
    loveLanguages: observeLoveLanguages(_actsFrom(entries)),
  );
}

/// The couple acts the user recorded, in the two directions that matter: what
/// they gave, and what their partner said they valued.
List<Act> _actsFrom(Iterable<LocalDomainEntry> entries) => [
      for (final e in entries)
        if (e.type == 'couple_act' && _string(e.data['what']).isNotEmpty)
          Act(
            text: _string(e.data['what']),
            by: _string(e.data['side']) == 'valued' ? Side.partner : Side.user,
          ),
    ];

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

  // A PERSON TOLD IN PIECES IS STILL ONE PERSON.
  //
  // You record "Oscar García, cumpleaños 10/07" today and remember next week
  // that he is your brother-in-law. Two entries, one human — and taking the
  // newest RECORD whole silently erased the birthday, because the second entry
  // carried a relation and no date. Nothing failed and nothing warned: the date
  // simply stopped existing, along with the reminder it fed.
  //
  // So the merge is per FIELD: the newest value the user gave for each field
  // wins, and a field they never mentioned again survives untouched. A
  // correction still overrides, because the newest value is the one they meant.
  final byKey = <String, _Person>{};
  final ordered = persons.toList()..sort((a, b) => b.knownSince.compareTo(a.knownSince));
  for (final p in ordered) {
    final key = _key(p.name);
    final known = byKey[key];
    byKey[key] = known == null
        ? p
        : _Person(
            // The name as most recently written, so a corrected spelling shows.
            name: known.name,
            // ...but known since the FIRST time they were recorded: that is
            // when this person entered your life, not when you last edited them.
            knownSince: p.knownSince,
            relation: known.relation ?? p.relation,
            birthDate: known.birthDate ?? p.birthDate,
            contactEveryDays: known.contactEveryDays ?? p.contactEveryDays,
          );
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
        family: _familyOf(p, byKey, _resolveTargets(byKey)),
      ),
  ];
}

/// Each person's relation phrase resolved to the person it NAMES, or null when
/// it names nobody — or names more than one.
///
/// Ambiguity resolves to nothing on purpose. Two Juanes and a "hija de Juan"
/// could be guessed at, and a wrong guess puts someone else's daughter in your
/// friend's picture with no way for the user to tell it is wrong. No link is a
/// visible absence; the wrong link is a silent lie.
Map<String, String?> _resolveTargets(Map<String, _Person> byKey) {
  final out = <String, String?>{};
  for (final entry in byKey.entries) {
    final target = _relationTarget(entry.value.relation);
    if (target == null) {
      out[entry.key] = null;
      continue;
    }
    final matches = [
      for (final other in byKey.keys)
        if (other != entry.key && _sameHuman(other, target)) other,
    ];
    out[entry.key] = matches.length == 1 ? matches.single : null;
  }
  return out;
}

/// Whether two written names refer to the same person.
///
/// People record a contact in full — "Juan Pérez García" — and then describe
/// his daughter the way they would SAY it: "hija de Juan". Requiring an exact
/// match meant that pairing silently never linked, which is the common case
/// rather than the edge one.
///
/// The match is on WHOLE leading words, never a prefix of a word: "Juana" is
/// not "Juan".
bool _sameHuman(String a, String b) => a == b || a.startsWith('$b ') || b.startsWith('$a ');

/// The people whose `relation` points AT [owner] — "hija de Juan" belongs to
/// Juan's picture, and their birthdays are usually the better reason to write.
List<TrackedPerson> _familyOf(
  _Person owner,
  Map<String, _Person> byKey,
  Map<String, String?> targets,
) {
  final ownerKey = _key(owner.name);
  final out = <TrackedPerson>[];
  for (final other in byKey.values) {
    final otherKey = _key(other.name);
    if (otherKey == ownerKey) continue;
    if (targets[otherKey] != ownerKey) continue;
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
