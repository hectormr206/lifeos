// Proves the DETERMINISTIC health-metric parser: the exact user examples parse
// to the right typed entry + subject, the physiological range gates reject
// non-vital numbers, and glucose/weight/sleep shapes work — all model-free.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/health_parser.dart';

void main() {
  group('blood pressure — the crown-jewel examples', () {
    test('"122 77 55 pulsos" → MY BP, dated self (no marker)', () {
      final p = parseHealthEntry('122 77 55 pulsos');
      expect(p, isNotNull);
      expect(p!.domainKey, 'health');
      expect(p.type, 'blood_pressure');
      expect(p.fields, {'systolic': 122, 'diastolic': 77, 'pulse': 55});
      expect(p.title, 'presión 122/77, pulso 55');
      expect(p.subject, isNull); // mine
    });

    test('"esta vez me salió 121 75, 70 pulsos" → mine (no relation marker)', () {
      final p = parseHealthEntry('esta vez me salió 121 75, 70 pulsos');
      expect(p, isNotNull);
      expect(p!.fields, {'systolic': 121, 'diastolic': 75, 'pulse': 70});
      expect(p.subject, isNull);
    });

    test('"de mi esposa son 120, 60, 49 pulsos" → wife (leading marker)', () {
      final p = parseHealthEntry('de mi esposa son 120, 60, 49 pulsos');
      expect(p, isNotNull);
      expect(p!.fields, {'systolic': 120, 'diastolic': 60, 'pulse': 49});
      expect(p.subject, 'esposa');
    });

    test('"esto le salió a mi papá 135, 89, 95 pulsos" → dad (mid marker)', () {
      final p = parseHealthEntry('esto le salió a mi papá 135, 89, 95 pulsos');
      expect(p, isNotNull);
      expect(p!.fields, {'systolic': 135, 'diastolic': 89, 'pulse': 95});
      expect(p.subject, 'papá');
    });

    test('"Mi esposa tuvo 121, 79, 61 pulsos" → wife (leading marker + verb)', () {
      final p = parseHealthEntry('Mi esposa tuvo 121, 79, 61 pulsos');
      expect(p, isNotNull);
      expect(p!.fields, {'systolic': 121, 'diastolic': 79, 'pulse': 61});
      expect(p.subject, 'esposa');
    });

    test('keyword BP with pulse: "presión 120/80 pulso 70"', () {
      final p = parseHealthEntry('presión 120/80 pulso 70');
      expect(p!.fields, {'systolic': 120, 'diastolic': 80, 'pulse': 70});
    });

    test('keyword BP, no pulse: "presión 118/79" → sys/dia only', () {
      final p = parseHealthEntry('presión 118/79');
      expect(p!.type, 'blood_pressure');
      expect(p.fields, {'systolic': 118, 'diastolic': 79});
      expect(p.title, 'presión 118/79');
    });

    test('comma-dictated keyword BP with "y" pulse: "presión 122, 81, y 53 pulsos"', () {
      // Regression: the comma between sys and dia (voice dictation) plus the
      // conjunction before the pulse used to yield ZERO structured entries.
      final p = parseHealthEntry('presión 122, 81, y 53 pulsos');
      expect(p, isNotNull);
      expect(p!.type, 'blood_pressure');
      expect(p.fields, {'systolic': 122, 'diastolic': 81, 'pulse': 53});
    });

    test('comma-dictated keyword BP without pulse: "presión 122, 81"', () {
      final p = parseHealthEntry('presión 122, 81');
      expect(p!.type, 'blood_pressure');
      expect(p.fields, {'systolic': 122, 'diastolic': 81});
    });

    test('bare comma reading with "y" pulse: "130, 85, y 60 pulsos"', () {
      final p = parseHealthEntry('130, 85, y 60 pulsos');
      expect(p, isNotNull);
      expect(p!.fields, {'systolic': 130, 'diastolic': 85, 'pulse': 60});
    });
  });

  group('range gates reject non-vital numbers (precision-first)', () {
    test('out-of-range bare triple → null (sys 300, dia 400)', () {
      expect(parseHealthEntry('el total fue 300, 400, 500 pulsos'), isNull);
    });

    test('below-range triple → null ("12, 14, 18 pulsos")', () {
      expect(parseHealthEntry('12, 14, 18 pulsos'), isNull);
    });

    test('bare numbers with NO pulse keyword never fire', () {
      expect(parseHealthEntry('gasté 300 y 200 en el súper'), isNull);
    });

    test('a family marker whose reading is out of range → null (no mis-file)', () {
      expect(parseHealthEntry('de mi esposa 300, 400, 500 pulsos'), isNull);
    });
  });

  group('glucose / weight / sleep', () {
    test('glucose: "glucosa 110" → value 110', () {
      final p = parseHealthEntry('glucosa 110');
      expect(p!.type, 'glucose');
      expect(p.fields, {'value': 110});
      expect(p.title, 'glucosa 110 mg/dL');
    });

    test('weight: "peso 82" → 82 kg', () {
      final p = parseHealthEntry('peso 82');
      expect(p!.type, 'weight');
      expect(p.fields, {'value': 82.0});
      expect(p.title, 'peso 82 kg');
    });

    test('weight with unit: "me pesé 79.5 kg" → 79.5 kg', () {
      final p = parseHealthEntry('me pesé 79.5 kg');
      expect(p!.type, 'weight');
      expect(p.fields, {'value': 79.5});
    });

    test('weight in pounds converts to kg before the gate', () {
      final p = parseHealthEntry('weight 150 pounds');
      expect(p!.type, 'weight');
      expect((p.fields['value'] as num).toDouble(), closeTo(68.0, 0.2));
    });

    test('sleep: "dormí 7 horas" → 7h', () {
      final p = parseHealthEntry('dormí 7 horas');
      expect(p!.type, 'sleep_hours');
      expect(p.fields, {'hours': 7.0});
      expect(p.title, 'dormí 7h');
    });

    test('sleep half-hour: "dormí 6 horas y media" → 6.5h', () {
      final p = parseHealthEntry('dormí 6 horas y media');
      expect(p!.fields, {'hours': 6.5});
    });

    test('weight subject: "de mi esposa peso 70" → wife', () {
      final p = parseHealthEntry('de mi esposa peso 70');
      expect(p!.type, 'weight');
      expect(p.subject, 'esposa');
    });
  });

  group('no health signal', () {
    test('casual chat → null (raw-fact fallback owns it)', () {
      expect(parseHealthEntry('hola Axi cómo estás'), isNull);
      expect(parseHealthEntry(''), isNull);
    });
  });
}
