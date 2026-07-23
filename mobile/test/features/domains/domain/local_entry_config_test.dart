// Proves the LOCAL entry-type registry (native domain CRUD) is complete and
// well-formed for ALL 7 domains: every descriptor has types, every type's
// fields drive the generated form (enum fields carry options, every type is
// datable), the laptop's per-domain types are ported, label rendering, and
// the hoy/semana/mes/todo period math.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/domain/domain_form_spec.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';

void main() {
  group('registry completeness', () {
    test('every registered domain descriptor has at least one local entry type', () {
      for (final descriptor in domainDescriptors) {
        expect(localEntryTypesFor(descriptor.key), isNotEmpty,
            reason: 'domain ${descriptor.key} has no local entry types');
      }
    });

    test('registry keys match the descriptor registry exactly (no orphans)', () {
      expect(
        localEntryTypesByDomain.keys.toSet(),
        domainDescriptors.map((d) => d.key).toSet(),
      );
    });

    test('ports the laptop per-domain types (data.type wire values)', () {
      Set<String> typesOf(String key) => localEntryTypesFor(key).map((t) => t.type).toSet();

      expect(typesOf('health'),
          containsAll(['blood_pressure', 'glucose', 'weight', 'sleep_hours', 'symptom']));
      expect(typesOf('finance'), containsAll(['expense', 'income']));
      expect(typesOf('exercise'), containsAll(['workout', 'steps']));
      expect(typesOf('relationships'), contains('interaction'));
      expect(typesOf('learning'), contains('study'));
      expect(typesOf('spirituality'), contains('practice'));
      expect(typesOf('calendar'), contains('event'));
    });

    test('every type is well-formed: fields present, a required date field, valid enums', () {
      for (final entry in localEntryTypesByDomain.entries) {
        for (final type in entry.value) {
          expect(type.label, isNotEmpty);
          expect(type.fields, isNotEmpty, reason: '${entry.key}/${type.type} has no fields');
          final ts = type.fields.where((f) => f.key == 'ts' && f.type == DomainFieldType.date);
          expect(ts, hasLength(1), reason: '${entry.key}/${type.type} needs one ts date field');
          expect(ts.first.required, isTrue);
          expect(type.fields.where((f) => f.required && f.key != 'ts'), isNotEmpty,
              reason: '${entry.key}/${type.type} needs at least one required content field');
          for (final field in type.fields) {
            if (field.type == DomainFieldType.enumType) {
              expect(field.enumOptions, isNotNull);
              expect(field.enumOptions, isNotEmpty,
                  reason: '${entry.key}/${type.type}.${field.key} enum without options');
            }
          }
        }
      }
    });

    test('type keys are unique within each domain', () {
      for (final entry in localEntryTypesByDomain.entries) {
        final keys = entry.value.map((t) => t.type).toList();
        expect(keys.toSet().length, keys.length, reason: 'duplicate type in ${entry.key}');
      }
    });

    test('localEntryTypeFor resolves known types and rejects null/unknown', () {
      expect(localEntryTypeFor('health', 'blood_pressure')?.label, 'Presión arterial');
      expect(localEntryTypeFor('health', null), isNull);
      expect(localEntryTypeFor('health', 'expense'), isNull);
      expect(localEntryTypeFor('nope', 'expense'), isNull);
    });
  });

  group('label rendering', () {
    test('blood pressure renders sys/dia with optional pulse and note', () {
      final bp = localEntryTypeFor('health', 'blood_pressure')!;
      expect(renderLocalEntryLabel(bp, {'systolic': 120, 'diastolic': 80}), 'Presión 120/80');
      expect(
        renderLocalEntryLabel(bp, {'systolic': 120, 'diastolic': 80, 'pulse': 72, 'note': 'en ayunas'}),
        'Presión 120/80 · 72 lpm — en ayunas',
      );
    });

    test('finance labels carry the amount (and category/source)', () {
      final expense = localEntryTypeFor('finance', 'expense')!;
      final income = localEntryTypeFor('finance', 'income')!;
      expect(renderLocalEntryLabel(expense, {'amount': 250, 'category': 'comida'}), 'Gasto \$250 · comida');
      expect(renderLocalEntryLabel(income, {'amount': 1000}), 'Ingreso \$1000');
    });

    test('every type renders a non-empty label from its required fields', () {
      for (final entry in localEntryTypesByDomain.entries) {
        for (final type in entry.value) {
          final values = <String, Object?>{
            for (final f in type.fields)
              if (f.required && f.key != 'ts')
                f.key: switch (f.type) {
                  DomainFieldType.enumType => f.enumOptions!.first,
                  DomainFieldType.text => 'algo',
                  _ => 5,
                },
          };
          expect(renderLocalEntryLabel(type, values).trim(), isNotEmpty,
              reason: '${entry.key}/${type.type} rendered an empty label');
        }
      }
    });
  });

  group('period math (hoy/semana/mes/todo, local midnight anchors)', () {
    final now = DateTime(2026, 7, 23, 15, 30); // a fixed local afternoon

    test('hoy starts at today\'s midnight', () {
      expect(LocalEntryPeriod.hoy.startFor(now), DateTime(2026, 7, 23));
    });

    test('semana covers 7 calendar days including today', () {
      expect(LocalEntryPeriod.semana.startFor(now), DateTime(2026, 7, 17));
    });

    test('mes covers 30 calendar days including today (crosses the month)', () {
      expect(LocalEntryPeriod.mes.startFor(now), DateTime(2026, 6, 24));
    });

    test('todo is unbounded', () {
      expect(LocalEntryPeriod.todo.startFor(now), isNull);
    });
  });
}
