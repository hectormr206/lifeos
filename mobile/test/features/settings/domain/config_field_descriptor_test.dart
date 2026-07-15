// Proves `buildConfigDescriptors` merges the engine's REAL two config
// shapes (read from axi/src/axi/config_schema.py):
//   - `GET /api/v1/config/schema` -> `to_json_schema()` (config_schema.py:1050):
//     `{"$schema", "title", "type", "additionalProperties", "properties":
//     {name: {type, default, description?, minimum?, maximum?, enum?}}}`.
//   - `GET /api/v1/config` -> a flat `{name: value}` dict (`dashboard.py:1662
//     read_config` -> `dict(config._load())`).
// into one typed [ConfigFieldDescriptor] list covering every field type
// (boolean/integer/number/string/enum), plus client-side numeric bounds
// validation mirroring `ConfigField.validate`'s minimum/maximum check.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/settings/domain/config_field_descriptor.dart';

void main() {
  group('buildConfigDescriptors', () {
    test('merges schema + current values for every field type', () {
      final schema = {
        'properties': {
          'tts_enabled': {'type': 'boolean', 'default': true, 'description': 'Habla las respuestas.'},
          'meeting_window_minutes': {
            'type': 'integer',
            'default': 15,
            'minimum': 1,
            'maximum': 120,
            'description': 'Ventana de resumen jerárquico.',
          },
          'meeting_silence_rms': {'type': 'number', 'default': 0.015, 'minimum': 0.0001, 'maximum': 0.5},
          'user_name': {'type': 'string', 'default': ''},
          'language': {
            'type': 'string',
            'default': 'es-MX',
            'enum': ['es-MX', 'es', 'en'],
          },
        },
      };
      final values = {
        'tts_enabled': false,
        'meeting_window_minutes': 20,
        'meeting_silence_rms': 0.02,
        'user_name': 'Héctor',
        'language': 'es',
      };

      final descriptors = buildConfigDescriptors(schema: schema, values: values);

      expect(descriptors, hasLength(5));

      final tts = descriptors.firstWhere((f) => f.name == 'tts_enabled');
      expect(tts.type, ConfigValueType.boolean);
      expect(tts.value, false);
      expect(tts.description, 'Habla las respuestas.');

      final window = descriptors.firstWhere((f) => f.name == 'meeting_window_minutes');
      expect(window.type, ConfigValueType.integer);
      expect(window.value, 20);
      expect(window.minimum, 1);
      expect(window.maximum, 120);

      final rms = descriptors.firstWhere((f) => f.name == 'meeting_silence_rms');
      expect(rms.type, ConfigValueType.number);
      expect(rms.value, 0.02);
      expect(rms.minimum, 0.0001);
      expect(rms.maximum, 0.5);

      final name = descriptors.firstWhere((f) => f.name == 'user_name');
      expect(name.type, ConfigValueType.string);
      expect(name.value, 'Héctor');
      expect(name.isEnum, isFalse);

      final language = descriptors.firstWhere((f) => f.name == 'language');
      expect(language.type, ConfigValueType.string);
      expect(language.value, 'es');
      expect(language.isEnum, isTrue);
      expect(language.enumValues, ['es-MX', 'es', 'en']);
    });

    test('a schema field missing from the current values dict falls back to its schema default', () {
      final schema = {
        'properties': {
          'vision_enabled': {'type': 'boolean', 'default': true},
        },
      };

      final descriptors = buildConfigDescriptors(schema: schema, values: const {});

      expect(descriptors.single.value, true);
    });

    test('a current value with no matching schema property is skipped (unknown field)', () {
      final schema = {
        'properties': {
          'user_name': {'type': 'string', 'default': ''},
        },
      };
      final values = {'user_name': 'Héctor', 'some_unlisted_key': 42};

      final descriptors = buildConfigDescriptors(schema: schema, values: values);

      expect(descriptors, hasLength(1));
      expect(descriptors.single.name, 'user_name');
    });

    test('descriptors are sorted by field name for a deterministic UI order', () {
      final schema = {
        'properties': {
          'zeta_field': {'type': 'string', 'default': ''},
          'alpha_field': {'type': 'string', 'default': ''},
        },
      };

      final descriptors = buildConfigDescriptors(schema: schema, values: const {});

      expect(descriptors.map((f) => f.name).toList(), ['alpha_field', 'zeta_field']);
    });

    test('a malformed schema (no properties map) degrades to an empty list', () {
      expect(buildConfigDescriptors(schema: const {}, values: const {}), isEmpty);
    });
  });

  group('ConfigFieldDescriptor.validate (client-side numeric bounds)', () {
    const field = ConfigFieldDescriptor(
      name: 'meeting_window_minutes',
      type: ConfigValueType.integer,
      value: 15,
      minimum: 1,
      maximum: 120,
    );

    test('a value within bounds is valid', () {
      expect(field.validate(60), isNull);
    });

    test('a value below the minimum is rejected', () {
      expect(field.validate(0), isNotNull);
    });

    test('a value above the maximum is rejected', () {
      expect(field.validate(200), isNotNull);
    });

    test('a non-numeric candidate for a numeric field is rejected', () {
      expect(field.validate('not a number'), isNotNull);
    });

    test('non-numeric field types are never bounds-checked', () {
      const stringField = ConfigFieldDescriptor(name: 'user_name', type: ConfigValueType.string, value: '');
      expect(stringField.validate('anything'), isNull);
    });
  });
}
