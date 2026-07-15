// DomainEntry value-equality + defaults only (spec mobile-domain-crud).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_entry.dart';

void main() {
  test('DomainEntry value-equality compares id/title/timestamp/subject', () {
    final ts = DateTime.utc(2026, 1, 1);
    final a = DomainEntry(id: '1', title: 'Presión', timestamp: ts);
    final b = DomainEntry(id: '1', title: 'Presión', timestamp: ts);
    final c = DomainEntry(id: '1', title: 'Presión', timestamp: ts, subject: 'esposa');

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('subject defaults to null and raw defaults to an empty map', () {
    final entry = DomainEntry(id: '1', title: 'x', timestamp: DateTime.now());

    expect(entry.subject, isNull);
    expect(entry.raw, isEmpty);
  });
}
