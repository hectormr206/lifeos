// Proves the per-domain field specs (spec: structured-domain-forms) match
// the engine's EXACT create-endpoint request bodies (read directly from
// axi/src/axi/dashboard.py, never guessed — see domain_form_spec.dart's own
// per-domain doc comments for the exact line refs) and that
// buildDomainEntryBody builds the exact POST body shape for at least
// health/finance/exercise, per the apply constraints.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_form_spec.dart';

void main() {
  group('domainFormSpecFor', () {
    test('health declares kind (required enum), title, ts, and vitals data fields', () {
      final spec = domainFormSpecFor('health');
      expect(spec.map((f) => f.key), containsAll(['kind', 'title', 'ts', 'systolic', 'diastolic']));

      final kind = spec.firstWhere((f) => f.key == 'kind');
      expect(kind.type, DomainFieldType.enumType);
      expect(kind.required, isTrue);
      expect(kind.enumOptions, containsAll(['symptom', 'medication', 'vital', 'condition', 'note']));

      final systolic = spec.firstWhere((f) => f.key == 'systolic');
      expect(systolic.dataKey, 'systolic');
      expect(systolic.type, DomainFieldType.integer);
    });

    test('finance declares amount as a required number field with a non-negative bound', () {
      final spec = domainFormSpecFor('finance');
      final amount = spec.firstWhere((f) => f.key == 'amount');
      expect(amount.type, DomainFieldType.number);
      expect(amount.required, isTrue);
      expect(amount.min, 0);

      final kind = spec.firstWhere((f) => f.key == 'kind');
      expect(kind.enumOptions, contains('big_purchase'));
    });

    test('exercise declares duration_minutes as a required integer field', () {
      final spec = domainFormSpecFor('exercise');
      final duration = spec.firstWhere((f) => f.key == 'duration_minutes');
      expect(duration.type, DomainFieldType.integer);
      expect(duration.required, isTrue);

      final kind = spec.firstWhere((f) => f.key == 'kind');
      expect(kind.enumOptions, contains('run'));
    });

    test('relationships requires person_id as free text', () {
      final spec = domainFormSpecFor('relationships');
      final personId = spec.firstWhere((f) => f.key == 'person_id');
      expect(personId.type, DomainFieldType.text);
      expect(personId.required, isTrue);
    });

    test('calendar declares kind options matching the engine Kind literal', () {
      final spec = domainFormSpecFor('calendar');
      final kind = spec.firstWhere((f) => f.key == 'kind');
      expect(kind.enumOptions, containsAll(['travel', 'birthday', 'meeting']));
    });

    test('an unknown domain key returns an empty spec (never throws)', () {
      expect(domainFormSpecFor('unknown-domain'), isEmpty);
    });

    test('all 7 domains have a non-empty spec', () {
      for (final key in ['health', 'finance', 'exercise', 'relationships', 'spirituality', 'learning', 'calendar']) {
        expect(domainFormSpecFor(key), isNotEmpty, reason: '$key should declare form fields');
      }
    });
  });

  group('buildDomainEntryBody', () {
    test('builds the exact health POST body, nesting systolic/diastolic under "data"', () {
      final spec = domainFormSpecFor('health');
      final body = buildDomainEntryBody(spec, {
        'kind': 'vital',
        'title': 'Presión',
        'ts': DateTime.utc(2026, 1, 1, 10),
        'systolic': 120,
        'diastolic': 80,
      });

      expect(body['kind'], 'vital');
      expect(body['title'], 'Presión');
      expect(body['ts'], '2026-01-01T10:00:00.000Z');
      expect(body['data'], {'systolic': 120, 'diastolic': 80});
      expect(body.containsKey('systolic'), isFalse, reason: 'systolic must nest under data, not be top-level');
    });

    test('builds the exact finance POST body with only the provided optional fields', () {
      final spec = domainFormSpecFor('finance');
      final body = buildDomainEntryBody(spec, {
        'kind': 'expense',
        'title': 'Súper',
        'amount': 500.0,
        'ts': DateTime.utc(2026, 1, 1, 10),
        'category': 'food',
      });

      expect(body, {
        'kind': 'expense',
        'title': 'Súper',
        'amount': 500.0,
        'ts': '2026-01-01T10:00:00.000Z',
        'category': 'food',
      });
      expect(body.containsKey('merchant'), isFalse);
      expect(body.containsKey('currency'), isFalse);
    });

    test('builds the exact exercise POST body', () {
      final spec = domainFormSpecFor('exercise');
      final body = buildDomainEntryBody(spec, {
        'kind': 'run',
        'title': 'Carrera matutina',
        'duration_minutes': 30,
        'ts': DateTime.utc(2026, 1, 1, 8),
      });

      expect(body, {
        'kind': 'run',
        'title': 'Carrera matutina',
        'duration_minutes': 30,
        'ts': '2026-01-01T08:00:00.000Z',
      });
    });

    test('a field with a null/absent value is omitted entirely, never sent as null', () {
      final spec = domainFormSpecFor('finance');
      final body = buildDomainEntryBody(spec, {
        'kind': 'expense',
        'title': 'Café',
        'amount': 50.0,
        'ts': DateTime.utc(2026, 1, 1),
        'merchant': null,
      });

      expect(body.containsKey('merchant'), isFalse);
    });
  });
}
