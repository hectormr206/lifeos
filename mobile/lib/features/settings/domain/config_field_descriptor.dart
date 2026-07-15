/// The value type of a config field, mirroring `config_schema.py`'s
/// `ConfigField.type` string literals ("string" | "boolean" | "integer" |
/// "number") one-to-one.
enum ConfigValueType { boolean, integer, number, string }

ConfigValueType _typeFromSchema(Object? raw) {
  switch (raw) {
    case 'boolean':
      return ConfigValueType.boolean;
    case 'integer':
      return ConfigValueType.integer;
    case 'number':
      return ConfigValueType.number;
    default:
      return ConfigValueType.string;
  }
}

/// One config field, ready for schema-driven UI rendering: the engine's
/// static schema description (type, bounds, enum choices) merged with the
/// current runtime value. Built by [buildConfigDescriptors] — never
/// constructed by hand from raw JSON outside tests.
class ConfigFieldDescriptor {
  const ConfigFieldDescriptor({
    required this.name,
    required this.type,
    required this.value,
    this.description,
    this.minimum,
    this.maximum,
    this.enumValues,
  });

  final String name;
  final ConfigValueType type;

  /// The current value (from `GET /api/v1/config`, or the schema's own
  /// `default` when the key is absent there). Runtime type matches [type]:
  /// `bool` | `int` | `num` | `String`.
  final Object? value;

  final String? description;

  /// Numeric bounds (`ConfigField.minimum`/`maximum`) — only ever set for
  /// [ConfigValueType.integer]/[ConfigValueType.number] fields.
  final num? minimum;
  final num? maximum;

  /// Allowed values (`ConfigField.choices`) — only ever set for
  /// [ConfigValueType.string] fields with an enum constraint (e.g.
  /// `language`). `null`/empty means "free text", not "enum with zero
  /// choices".
  final List<String>? enumValues;

  bool get isEnum => enumValues != null && enumValues!.isNotEmpty;

  /// Client-side numeric bounds validation, mirroring
  /// `ConfigField.validate`'s `minimum`/`maximum` check (`config_schema.py`)
  /// so an out-of-range value is caught before the round trip. Returns a
  /// Spanish user-facing error message, or `null` if [candidate] is valid.
  /// Non-numeric field types are never bounds-checked — always valid here
  /// (string enum membership and other constraints are the engine's job,
  /// surfaced via the POST error path instead of duplicated client-side).
  String? validate(Object? candidate) {
    if (type != ConfigValueType.integer && type != ConfigValueType.number) return null;
    final numeric = candidate is num ? candidate : num.tryParse(candidate?.toString() ?? '');
    if (numeric == null) return 'Debe ser un número.';
    if (minimum != null && numeric < minimum!) return 'Debe ser mayor o igual a $minimum.';
    if (maximum != null && numeric > maximum!) return 'Debe ser menor o igual a $maximum.';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ConfigFieldDescriptor && other.name == name && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(name, type, value);

  @override
  String toString() => 'ConfigFieldDescriptor(name: $name, type: $type, value: $value)';
}

/// Merges the engine's `GET /api/v1/config/schema` (`config_schema.py`'s
/// `to_json_schema()`, JSON-Schema-ish `{"properties": {name: {type,
/// default, description?, minimum?, maximum?, enum?}}}`) with `GET
/// /api/v1/config` (a flat `{name: value}` dict — `dashboard.py:1662
/// read_config` returns `dict(config._load())`) into one typed descriptor
/// list, sorted by field name for a stable, deterministic UI order.
///
/// - A schema property with no matching current value falls back to the
///   schema's own `default` (fresh install / a key the on-disk config
///   hasn't written yet).
/// - A current value with no matching schema property is SKIPPED — the
///   schema's `additionalProperties: true` means the engine tolerates
///   unknown keys, but the UI only renders KNOWN, typed fields; rendering
///   an untyped field would have no widget mapping to use.
List<ConfigFieldDescriptor> buildConfigDescriptors({
  required Map<String, Object?> schema,
  required Map<String, Object?> values,
}) {
  final properties = schema['properties'];
  if (properties is! Map) return const [];

  final descriptors = <ConfigFieldDescriptor>[];
  for (final entry in properties.entries) {
    final name = entry.key.toString();
    final prop = entry.value;
    if (prop is! Map) continue;

    final enumRaw = prop['enum'];
    final enumValues = enumRaw is List ? enumRaw.map((e) => e.toString()).toList() : null;
    final value = values.containsKey(name) ? values[name] : prop['default'];

    descriptors.add(ConfigFieldDescriptor(
      name: name,
      type: _typeFromSchema(prop['type']),
      value: value,
      description: prop['description'] as String?,
      minimum: prop['minimum'] as num?,
      maximum: prop['maximum'] as num?,
      enumValues: enumValues,
    ));
  }
  descriptors.sort((a, b) => a.name.compareTo(b.name));
  return descriptors;
}
