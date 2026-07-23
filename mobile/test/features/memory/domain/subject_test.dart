import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/subject.dart';

/// SLICE A3 — family-subject detection (ported from _common/subject.py).
void main() {
  group('detectSubject', () {
    test('leading marker with verb keeps + strips the verb', () {
      final m = detectSubject('Mi esposa tuvo 121, 79, 61 pulsos');
      expect(m, isNotNull);
      expect(m!.subject, 'esposa');
      expect(m.remainder, 'tuvo 121, 79, 61 pulsos');
      expect(m.remainderNoVerb, '121, 79, 61 pulsos');
    });

    test('trailing marker strips the "de mi X" tail', () {
      final m = detectSubject('108, 72, 66 pulsos de mi esposa');
      expect(m!.subject, 'esposa');
      expect(m.remainder, '108, 72, 66 pulsos');
      expect(m.remainderNoVerb, isNull);
    });

    test('EN synonym collapses to canonical ES label', () {
      final m = detectSubject('My wife slept 7 hours');
      expect(m!.subject, 'esposa');
      expect(m.remainder, 'slept 7 hours');
    });

    test('accent-free dictation still matches ("mi mama")', () {
      final m = detectSubject('mi mama durmió mal');
      expect(m!.subject, 'mamá');
    });

    test('unmarked text -> null (belongs to the user)', () {
      expect(detectSubject('presión 120/80'), isNull);
      expect(detectSubject('mi presión estaba alta'), isNull);
      expect(detectSubject(''), isNull);
    });
  });

  group('detectQuerySubject', () {
    test('possessive family marker anywhere returns the label', () {
      expect(detectQuerySubject('la presión de mi esposa ayer'), 'esposa');
      expect(detectQuerySubject('how did my mom sleep'), 'mamá');
    });

    test('self query -> null', () {
      expect(detectQuerySubject('mi presión'), isNull);
      expect(detectQuerySubject('resumen de salud'), isNull);
    });
  });

  group('subjectPossessive', () {
    test('ES and EN phrasing', () {
      expect(subjectPossessive('esposa'), 'tu esposa');
      expect(subjectPossessive('esposa', en: true), 'your wife');
    });
  });
}
