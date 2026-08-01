// Proves the sharing policy between two partners' assistants — and above all
// what it will NOT let across.
//
// The risk the feature carries is not a technical one. Connecting both
// assistants can turn a private journal into a surveilled relationship: if Axi
// knows what he feels and reports it, it stops being his assistant and becomes
// a monitor, and the effect on the relationship is the opposite of the one
// intended.
//
// The rule is EXPLICIT SHARING, NEVER SYNCHRONISATION. Only what the user
// sends across goes across, piece by piece. No mirrored moods, no automatic
// metrics. These tests are the enforcement.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/partner_sharing.dart';

void main() {
  group('what may cross', () {
    test('a date the user explicitly shares', () {
      final item = ShareableItem(
        kind: ShareKind.date,
        title: 'Aniversario',
        when: DateTime(2026, 9, 14),
      );

      expect(canShare(item), isTrue);
    });

    test('a reminder the user explicitly shares', () {
      final item = ShareableItem(
        kind: ShareKind.reminder,
        title: 'Cita con el dentista de Mateo',
        when: DateTime(2026, 4, 2),
      );

      expect(canShare(item), isTrue);
    });
  });

  group('what may never cross, no matter what', () {
    test('a mood', () {
      // The single most damaging thing to mirror. An assistant that reports
      // your mood to your partner destroys the private space that made it
      // useful in the first place.
      expect(
        () => ShareableItem(kind: ShareKind.mood, title: 'ansioso'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('health data', () {
      expect(
        () => ShareableItem(kind: ShareKind.health, title: 'presión 140/95'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('a private note', () {
      expect(
        () => ShareableItem(kind: ShareKind.note, title: 'lo que sentí hoy'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('the love-language observation', () {
      // Especially this. It is an observation ABOUT the relationship, made for
      // one person to reflect on. Sent across it becomes an accusation.
      expect(
        () => ShareableItem(
            kind: ShareKind.loveLanguageObservation, title: 'das servicio, ella quiere tiempo'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('explicit, never automatic', () {
    test('an outbox starts empty — nothing is queued by existing data', () {
      final outbox = ShareOutbox();

      expect(outbox.pending, isEmpty);
    });

    test('an item crosses only after the user sends it', () {
      final outbox = ShareOutbox();
      final anniversary = ShareableItem(
        kind: ShareKind.date,
        title: 'Aniversario',
        when: DateTime(2026, 9, 14),
      );

      expect(outbox.pending, isEmpty);
      outbox.share(anniversary);

      expect(outbox.pending.single.title, 'Aniversario');
    });

    test('sharing one thing does not enrol anything else', () {
      // The failure mode is a "share dates" toggle that quietly becomes a feed.
      final outbox = ShareOutbox();
      outbox.share(ShareableItem(
          kind: ShareKind.date, title: 'Aniversario', when: DateTime(2026, 9, 14)));
      outbox.share(ShareableItem(
          kind: ShareKind.reminder, title: 'Dentista', when: DateTime(2026, 4, 2)));

      expect(outbox.pending, hasLength(2));
      // Each is there because it was handed over, one at a time.
      expect(outbox.pending.map((i) => i.title), ['Aniversario', 'Dentista']);
    });

    test('a shared item can be taken back before it leaves', () {
      final outbox = ShareOutbox();
      final item = ShareableItem(
          kind: ShareKind.date, title: 'Aniversario', when: DateTime(2026, 9, 14));
      outbox.share(item);

      outbox.revoke(item);

      expect(outbox.pending, isEmpty);
    });

    test('there is no "share everything" affordance', () {
      // Not an oversight: the whole design is piece by piece. A bulk switch is
      // synchronisation wearing a different label.
      final outbox = ShareOutbox();

      expect(outbox.toString().toLowerCase(), isNot(contains('shareall')));
      expect(ShareOutbox.supportsBulkSharing, isFalse);
    });
  });

  group('the payload that would go on the wire', () {
    test('carries only the fields the partner needs to act on', () {
      final item = ShareableItem(
        kind: ShareKind.date,
        title: 'Aniversario',
        when: DateTime.utc(2026, 9, 14),
      );

      expect(item.toWire(), {
        'kind': 'date',
        'title': 'Aniversario',
        'when': '2026-09-14T00:00:00.000Z',
      });
    });

    test('no identifiers, no device info, no metrics ride along', () {
      final wire = ShareableItem(
        kind: ShareKind.reminder,
        title: 'Dentista',
        when: DateTime.utc(2026, 4, 2),
      ).toWire();

      for (final leak in ['user', 'device', 'id', 'mood', 'location', 'health']) {
        expect(wire.keys.any((k) => k.toLowerCase().contains(leak)), isFalse,
            reason: 'wire must not carry $leak');
      }
    });
  });
}
