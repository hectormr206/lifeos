// TODO(i18n): hardcoded neutral Spanish pending the i18n sweep (the domains
// screens predate the ARB slice and localize together in a later pass).

/// Per-domain LOCAL entry-type registry (native on-device domain CRUD).
///
/// Ports the laptop's per-domain structured entry types
/// (`axi/src/axi/domain_chat.py` / `domain_bridge.py` / the dashboard's
/// manual-entry forms) into ONE data-driven config: each domain key maps to a
/// list of [LocalEntryType]s, each carrying the typed [DomainFieldSpec] fields
/// that drive the SAME generated `DomainEntryForm` used by the engine forms —
/// no per-domain widget/repository code, ever (reusable-components principle,
/// same registry philosophy as `domainDescriptors` / `domainFormSpecs`).
///
/// Storage convention (A3, laptop wire-compat): every entry is a graph node
/// `kind: 'fact'` under the domain's graph key (calendar → 'lifeos-events'),
/// with `data.type` carrying the structured sub-type declared here
/// (blood_pressure/glucose/expense/...) and the typed field values flat in
/// `data`. Facts written by chat (C1) share the store but carry NO
/// `data.type` — the local list includes them as untyped rows.
library;

import 'domain_form_spec.dart';

/// One structured entry type of a domain (e.g. health → blood_pressure).
class LocalEntryType {
  const LocalEntryType({
    required this.type,
    required this.label,
    required this.fields,
    this.labelBuilder,
  });

  /// The `data.type` wire value (English, laptop-compatible).
  final String type;

  /// Neutral-Spanish display label (chips, form title, type picker).
  final String label;

  /// Typed fields driving the generated form. Every type includes the
  /// common [tsField] so all entries are datable/filterable by period.
  final List<DomainFieldSpec> fields;

  /// Optional custom graph-node label renderer; when null,
  /// [renderLocalEntryLabel] falls back to a generic "label + values" line.
  final String Function(Map<String, Object?> values)? labelBuilder;
}

// ── Shared fields (DRY: one const per recurring field) ─────────────────────

const DomainFieldSpec tsField =
    DomainFieldSpec(key: 'ts', label: 'Fecha y hora', type: DomainFieldType.date, required: true);

const DomainFieldSpec _noteField = DomainFieldSpec(key: 'note', label: 'Notas', type: DomainFieldType.text);

const DomainFieldSpec _durationField = DomainFieldSpec(
  key: 'duration_minutes',
  label: 'Duración',
  type: DomainFieldType.integer,
  min: 0,
  unitHint: 'min',
);

// ── Label renderers (top-level so the const registry can tear them off) ────

String _s(Object? v) => v?.toString() ?? '?';

String _withNote(String base, Map<String, Object?> v) {
  final note = v['note'];
  if (note is String && note.trim().isNotEmpty) return '$base — ${note.trim()}';
  return base;
}

String _bpLabel(Map<String, Object?> v) {
  final pulse = v['pulse'];
  final base = 'Presión ${_s(v['systolic'])}/${_s(v['diastolic'])}';
  return _withNote(pulse == null ? base : '$base · ${_s(pulse)} lpm', v);
}

String _glucoseLabel(Map<String, Object?> v) => _withNote('Glucosa ${_s(v['value'])} mg/dL', v);

String _weightLabel(Map<String, Object?> v) => _withNote('Peso ${_s(v['value'])} kg', v);

String _sleepLabel(Map<String, Object?> v) => _withNote('Sueño ${_s(v['hours'])} h', v);

String _titleLabel(Map<String, Object?> v) => _withNote(_s(v['title']), v);

String _expenseLabel(Map<String, Object?> v) {
  final category = v['category'];
  final base = 'Gasto \$${_s(v['amount'])}';
  return _withNote(category == null ? base : '$base · ${_s(category)}', v);
}

String _incomeLabel(Map<String, Object?> v) {
  final source = v['source'];
  final base = 'Ingreso \$${_s(v['amount'])}';
  return _withNote(source == null ? base : '$base · ${_s(source)}', v);
}

String _workoutLabel(Map<String, Object?> v) {
  final kind = _workoutKindLabels[v['kind']] ?? _s(v['kind']);
  return _withNote('$kind ${_s(v['duration_minutes'])} min', v);
}

String _stepsLabel(Map<String, Object?> v) => _withNote('${_s(v['steps'])} pasos', v);

String _interactionLabel(Map<String, Object?> v) => _withNote('Interacción con ${_s(v['person'])}', v);

String _studyLabel(Map<String, Object?> v) {
  final base = 'Estudio: ${_s(v['topic'])}';
  final minutes = v['duration_minutes'];
  return _withNote(minutes == null ? base : '$base · ${_s(minutes)} min', v);
}

String _practiceLabel(Map<String, Object?> v) {
  final kind = _practiceKindLabels[v['kind']] ?? _s(v['kind']);
  final minutes = v['duration_minutes'];
  return _withNote(minutes == null ? kind : '$kind · ${_s(minutes)} min', v);
}

// ── Enum display labels (wire values stay English/laptop-compatible) ───────

const Map<String, String> _workoutKindLabels = {
  'walk': 'Caminata',
  'run': 'Carrera',
  'cardio': 'Cardio',
  'strength': 'Fuerza',
  'yoga': 'Yoga',
  'sports': 'Deporte',
  'other': 'Otro',
};

const Map<String, String> _practiceKindLabels = {
  'meditation': 'Meditación',
  'prayer': 'Oración',
  'gratitude': 'Gratitud',
  'reflection': 'Reflexión',
  'other': 'Otra práctica',
};

// ── The registry: all 7 domains, pure data ──────────────────────────────────

/// LOCAL entry types per `DomainDescriptor.key`. Adding a type (or a whole
/// domain) is a pure data addition here — the form, list, chips, repository
/// and tests all derive from this map.
const Map<String, List<LocalEntryType>> localEntryTypesByDomain = {
  'health': [
    LocalEntryType(
      type: 'blood_pressure',
      label: 'Presión arterial',
      labelBuilder: _bpLabel,
      fields: [
        DomainFieldSpec(
            key: 'systolic', label: 'Sistólica', type: DomainFieldType.integer, required: true, min: 40, max: 300, unitHint: 'mmHg'),
        DomainFieldSpec(
            key: 'diastolic', label: 'Diastólica', type: DomainFieldType.integer, required: true, min: 20, max: 200, unitHint: 'mmHg'),
        DomainFieldSpec(key: 'pulse', label: 'Pulso', type: DomainFieldType.integer, min: 20, max: 260, unitHint: 'lpm'),
        tsField,
        _noteField,
      ],
    ),
    LocalEntryType(
      type: 'glucose',
      label: 'Glucosa',
      labelBuilder: _glucoseLabel,
      fields: [
        DomainFieldSpec(
            key: 'value', label: 'Glucosa', type: DomainFieldType.number, required: true, min: 0, unitHint: 'mg/dL'),
        tsField,
        _noteField,
      ],
    ),
    LocalEntryType(
      type: 'weight',
      label: 'Peso',
      labelBuilder: _weightLabel,
      fields: [
        DomainFieldSpec(key: 'value', label: 'Peso', type: DomainFieldType.number, required: true, min: 0, unitHint: 'kg'),
        tsField,
        _noteField,
      ],
    ),
    LocalEntryType(
      type: 'sleep_hours',
      label: 'Sueño',
      labelBuilder: _sleepLabel,
      fields: [
        DomainFieldSpec(
            key: 'hours', label: 'Horas de sueño', type: DomainFieldType.number, required: true, min: 0, max: 24, unitHint: 'h'),
        tsField,
        _noteField,
      ],
    ),
    LocalEntryType(
      type: 'symptom',
      label: 'Síntoma / nota',
      labelBuilder: _titleLabel,
      fields: [
        DomainFieldSpec(key: 'title', label: 'Síntoma o nota', type: DomainFieldType.text, required: true),
        tsField,
        _noteField,
      ],
    ),
  ],
  'finance': [
    LocalEntryType(
      type: 'expense',
      label: 'Gasto',
      labelBuilder: _expenseLabel,
      fields: [
        DomainFieldSpec(key: 'amount', label: 'Monto', type: DomainFieldType.number, required: true, min: 0, unitHint: 'MXN'),
        DomainFieldSpec(
          key: 'category',
          label: 'Categoría',
          type: DomainFieldType.enumType,
          enumOptions: ['comida', 'transporte', 'hogar', 'salud', 'ocio', 'servicios', 'educación', 'otro'],
        ),
        tsField,
        _noteField,
      ],
    ),
    LocalEntryType(
      type: 'income',
      label: 'Ingreso',
      labelBuilder: _incomeLabel,
      fields: [
        DomainFieldSpec(key: 'amount', label: 'Monto', type: DomainFieldType.number, required: true, min: 0, unitHint: 'MXN'),
        DomainFieldSpec(key: 'source', label: 'Fuente', type: DomainFieldType.text),
        tsField,
        _noteField,
      ],
    ),
  ],
  'exercise': [
    LocalEntryType(
      type: 'workout',
      label: 'Entrenamiento',
      labelBuilder: _workoutLabel,
      fields: [
        DomainFieldSpec(
          key: 'kind',
          label: 'Tipo',
          type: DomainFieldType.enumType,
          required: true,
          enumOptions: ['walk', 'run', 'cardio', 'strength', 'yoga', 'sports', 'other'],
          enumLabels: _workoutKindLabels,
        ),
        DomainFieldSpec(
            key: 'duration_minutes', label: 'Duración', type: DomainFieldType.integer, required: true, min: 0, unitHint: 'min'),
        tsField,
        _noteField,
      ],
    ),
    LocalEntryType(
      type: 'steps',
      label: 'Pasos',
      labelBuilder: _stepsLabel,
      fields: [
        DomainFieldSpec(key: 'steps', label: 'Pasos', type: DomainFieldType.integer, required: true, min: 0),
        tsField,
        _noteField,
      ],
    ),
  ],
  'relationships': [
    LocalEntryType(
      type: 'interaction',
      label: 'Interacción',
      labelBuilder: _interactionLabel,
      fields: [
        DomainFieldSpec(key: 'person', label: 'Persona', type: DomainFieldType.text, required: true),
        tsField,
        _noteField,
      ],
    ),
  ],
  'learning': [
    LocalEntryType(
      type: 'study',
      label: 'Estudio',
      labelBuilder: _studyLabel,
      fields: [
        DomainFieldSpec(key: 'topic', label: 'Tema', type: DomainFieldType.text, required: true),
        _durationField,
        tsField,
        _noteField,
      ],
    ),
  ],
  'spirituality': [
    LocalEntryType(
      type: 'practice',
      label: 'Práctica',
      labelBuilder: _practiceLabel,
      fields: [
        DomainFieldSpec(
          key: 'kind',
          label: 'Tipo',
          type: DomainFieldType.enumType,
          required: true,
          enumOptions: ['meditation', 'prayer', 'gratitude', 'reflection', 'other'],
          enumLabels: _practiceKindLabels,
        ),
        _durationField,
        tsField,
        _noteField,
      ],
    ),
  ],
  'calendar': [
    LocalEntryType(
      type: 'event',
      label: 'Evento',
      labelBuilder: _titleLabel,
      fields: [
        DomainFieldSpec(key: 'title', label: 'Título', type: DomainFieldType.text, required: true),
        DomainFieldSpec(key: 'ts', label: '¿Cuándo?', type: DomainFieldType.date, required: true),
        _noteField,
      ],
    ),
  ],
};

/// Types for one domain (empty for an unknown key — defensive, mirrors
/// `domainFormSpecFor`).
List<LocalEntryType> localEntryTypesFor(String domainKey) =>
    localEntryTypesByDomain[domainKey] ?? const [];

/// Resolve a stored `data.type` back to its config, or null (chat facts and
/// legacy rows carry no/unknown types and stay read-only in the UI).
LocalEntryType? localEntryTypeFor(String domainKey, String? type) {
  if (type == null) return null;
  for (final t in localEntryTypesFor(domainKey)) {
    if (t.type == type) return t;
  }
  return null;
}

/// Graph-node label for an entry: the type's custom builder, else a generic
/// "TypeLabel: v1 v2" line from the first non-ts/non-note field values.
String renderLocalEntryLabel(LocalEntryType type, Map<String, Object?> values) {
  final custom = type.labelBuilder;
  if (custom != null) return custom(values);
  final parts = <String>[type.label];
  for (final field in type.fields) {
    if (field.key == 'ts' || field.key == 'note') continue;
    final value = values[field.key];
    if (value == null) continue;
    parts.add(field.unitHint != null ? '$value ${field.unitHint}' : '$value');
  }
  return parts.join(' · ');
}

// ── Period filter (hoy/semana/mes/todo) ─────────────────────────────────────

/// The laptop dashboard's period filter, on-device. Windows are rolling and
/// midnight-anchored in LOCAL time: hoy = since today's midnight; semana =
/// since midnight 6 days ago (7 calendar days incl. today); mes = since
/// midnight 29 days ago (30 calendar days incl. today); todo = unbounded.
enum LocalEntryPeriod {
  hoy('Hoy'),
  semana('Semana'),
  mes('Mes'),
  todo('Todo');

  const LocalEntryPeriod(this.label);

  final String label;

  /// Inclusive lower bound (local time) for [now], or null (todo).
  DateTime? startFor(DateTime now) {
    final local = now.toLocal();
    final midnight = DateTime(local.year, local.month, local.day);
    switch (this) {
      case LocalEntryPeriod.hoy:
        return midnight;
      case LocalEntryPeriod.semana:
        return midnight.subtract(const Duration(days: 6));
      case LocalEntryPeriod.mes:
        return midnight.subtract(const Duration(days: 29));
      case LocalEntryPeriod.todo:
        return null;
    }
  }
}
