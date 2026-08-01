import 'package:flutter/foundation.dart' show immutable;

/// The widget-rendering type for one field in a domain's structured
/// create-entry form (spec: structured-domain-forms). Chosen purely by data
/// shape — the SAME reusable `DomainEntryForm` renders every domain from its
/// [DomainFieldSpec] list, no per-domain widget code, ever (mirrors
/// `DomainDescriptor`'s registry philosophy, design D2).
enum DomainFieldType { text, number, integer, enumType, date }

/// One field of a domain's create form: a POST-body key (or a synthetic
/// [dataKey] sub-key), a Spanish user-facing [label], a [type] that
/// determines which widget renders it, and per-type constraints.
@immutable
class DomainFieldSpec {
  const DomainFieldSpec({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.enumOptions,
    this.enumLabels,
    this.unitHint,
    this.min,
    this.max,
    this.dataKey,
    this.dateOnly = false,
  });

  /// The POST body key (top-level), UNLESS [dataKey] is set, in which case
  /// [key] is only the internal form-state identifier and the value nests
  /// under `body['data'][dataKey]` instead.
  final String key;

  final String label;
  final DomainFieldType type;
  final bool required;

  /// Choices for a [DomainFieldType.enumType] field. Required (non-null,
  /// non-empty) whenever [type] is [DomainFieldType.enumType].
  final List<String>? enumOptions;

  /// Optional Spanish display labels for [enumOptions] (wire value →
  /// user-facing text). Missing keys fall back to the raw option string —
  /// keeps stored values laptop-compatible while the UI stays in neutral
  /// Spanish (local-entry config, spec native-domain-crud).
  final Map<String, String>? enumLabels;

  /// Optional short unit hint shown as a field suffix (e.g. "mmHg", "min").
  final String? unitHint;

  /// Inclusive numeric bounds — only meaningful for
  /// [DomainFieldType.number]/[DomainFieldType.integer]. `null` = unbounded.
  final num? min;
  final num? max;

  /// When set, this field's value nests under a single top-level `"data"`
  /// object in the built POST body, keyed by [dataKey], instead of being a
  /// top-level key itself (e.g. health vitals: systolic/diastolic ->
  /// `{"data": {"systolic": 120, "diastolic": 80}}`, matching
  /// `health_entries.create(data=...)`'s free-form JSON dict).
  final String? dataKey;

  /// A calendar date with no time of day — a birth date, not a timestamp.
  ///
  /// The two differ in more than presentation. A timestamp is an instant and
  /// converts to UTC correctly; a birth date converted to UTC lands on the
  /// PREVIOUS DAY for anyone east of it, and the app would then celebrate the
  /// birthday a day early forever. So a [dateOnly] value serialises as a plain
  /// `YYYY-MM-DD` string and is never asked for a time.
  final bool dateOnly;
}

const _kindLabel = 'Tipo';
const _titleLabel = 'Título';
const _tsLabel = 'Fecha y hora';
const _bodyLabel = 'Notas';

/// Health (`POST /api/v1/health/entries`, dashboard.py:6107 `api_health_create`):
/// `{kind, title, ts, body?, data?, tags?, source?}`. `kind` options verified
/// against `lifeos/health/entries.py`'s `_VALID_KINDS`. `systolic`/`diastolic`
/// are a generic "vital" capture nested under `data` — the engine's `data`
/// field is a free-form JSON dict, so this slice surfaces the two most common
/// numeric vitals rather than a fully dynamic per-kind schema.
const List<DomainFieldSpec> _healthFields = [
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['symptom', 'medication', 'vital', 'condition', 'note'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(
    key: 'systolic',
    label: 'Sistólica',
    type: DomainFieldType.integer,
    unitHint: 'mmHg',
    dataKey: 'systolic',
  ),
  DomainFieldSpec(
    key: 'diastolic',
    label: 'Diastólica',
    type: DomainFieldType.integer,
    unitHint: 'mmHg',
    dataKey: 'diastolic',
  ),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// Finance (`POST /api/v1/finance/entries`, dashboard.py:6261
/// `api_finance_create`): `{kind, title, amount, ts, currency?, category?,
/// merchant?, body?}`. `kind` verified against
/// `lifeos/finance/entries.py`'s `_VALID_KINDS`. `amount` mirrors the
/// engine's own `amount < 0` rejection with a client-side `min: 0`.
const List<DomainFieldSpec> _financeFields = [
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['expense', 'income', 'savings', 'debt_payment', 'big_purchase', 'note'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'amount', label: 'Monto', type: DomainFieldType.number, required: true, min: 0, unitHint: 'MXN'),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(key: 'currency', label: 'Moneda', type: DomainFieldType.text),
  DomainFieldSpec(key: 'category', label: 'Categoría', type: DomainFieldType.text),
  DomainFieldSpec(key: 'merchant', label: 'Comercio', type: DomainFieldType.text),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// Exercise (`POST /api/v1/exercise/sessions`, dashboard.py:6556
/// `api_ex_create`): `{kind, title, duration_minutes, ts, intensity?,
/// mood_pre?, mood_post?, location?, body?}`. `kind` verified against
/// `lifeos/exercise/sessions.py`'s `Kind` literal.
const List<DomainFieldSpec> _exerciseFields = [
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['walk', 'run', 'cardio', 'strength', 'yoga', 'sports', 'other'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(
    key: 'duration_minutes',
    label: 'Duración',
    type: DomainFieldType.integer,
    required: true,
    min: 0,
    unitHint: 'min',
  ),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(key: 'intensity', label: 'Intensidad', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'mood_pre', label: 'Ánimo antes', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'mood_post', label: 'Ánimo después', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'location', label: 'Lugar', type: DomainFieldType.text),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// Relationships interactions (`POST /api/v1/relationships/interactions`,
/// dashboard.py:6479 `api_rel_interactions_create`): `{person_id, kind,
/// title, ts, body?, mood_pre?, mood_post?}`. `kind` verified against
/// `lifeos/relationships/interactions.py`'s `Kind` literal. `person_id` is a
/// free-text field in this slice — resolving it against the People registry
/// (`GET /api/v1/relationships/people`) is a documented follow-up.
const List<DomainFieldSpec> _relationshipsFields = [
  DomainFieldSpec(key: 'person_id', label: 'Persona (ID)', type: DomainFieldType.text, required: true),
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['conversation', 'conflict', 'quality_time', 'call', 'text', 'note'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(key: 'mood_pre', label: 'Ánimo antes', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'mood_post', label: 'Ánimo después', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// Spirituality (`POST /api/v1/spirituality/entries`, dashboard.py:6633
/// `api_spirit_create`): `{kind, title, ts, body?, mood?}`. `kind` verified
/// against `lifeos/spirituality/entries.py`'s `Kind` literal.
const List<DomainFieldSpec> _spiritualityFields = [
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['reflection', 'gratitude', 'meditation', 'value', 'retro', 'question'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(key: 'mood', label: 'Ánimo', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// Learning (`POST /api/v1/learning/entries`, dashboard.py:6708
/// `api_learn_create`): `{kind, title, ts, body?, author?, status?,
/// progress?, rating?}`. `kind`/`status` verified against
/// `lifeos/learning/entries.py`'s `Kind`/`Status` literals; `rating`
/// mirrors `_validate_rating`'s `1..10` bound.
const List<DomainFieldSpec> _learningFields = [
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['book', 'course', 'article', 'idea', 'research_question', 'note', 'quote'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(key: 'author', label: 'Autor', type: DomainFieldType.text),
  DomainFieldSpec(
    key: 'status',
    label: 'Estado',
    type: DomainFieldType.enumType,
    enumOptions: ['active', 'done', 'abandoned', 'someday'],
  ),
  DomainFieldSpec(key: 'progress', label: 'Progreso', type: DomainFieldType.text),
  DomainFieldSpec(key: 'rating', label: 'Calificación', type: DomainFieldType.integer, min: 1, max: 10),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// Calendar (`POST /api/v1/calendar`, dashboard.py:6860 `api_calendar_create`):
/// `{kind, title, ts, body?, location?, people?, data?}`. `kind` verified
/// against `lifeos/events/entries.py`'s `Kind` literal. `people` (a list
/// field on the engine) is a documented follow-up — this generic engine's
/// field types (text|number|integer|enumType|date) do not yet cover
/// multi-value fields.
const List<DomainFieldSpec> _calendarFields = [
  DomainFieldSpec(
    key: 'kind',
    label: _kindLabel,
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['travel', 'party', 'milestone', 'anniversary', 'birthday', 'meeting', 'deadline', 'other'],
  ),
  DomainFieldSpec(key: 'title', label: _titleLabel, type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'ts', label: _tsLabel, type: DomainFieldType.date, required: true),
  DomainFieldSpec(key: 'location', label: 'Lugar', type: DomainFieldType.text),
  DomainFieldSpec(key: 'body', label: _bodyLabel, type: DomainFieldType.text),
];

/// All 7 domains' create-form field specs, keyed by [DomainDescriptor.key].
/// The single source of truth [DomainEntryForm] renders from — adding a
/// domain's structured form is a pure data addition here, never a new
/// widget (same reusable-component invariant as `domainDescriptors`).
const Map<String, List<DomainFieldSpec>> domainFormSpecs = {
  'health': _healthFields,
  'finance': _financeFields,
  'exercise': _exerciseFields,
  'relationships': _relationshipsFields,
  'spirituality': _spiritualityFields,
  'learning': _learningFields,
  'calendar': _calendarFields,
};

/// Resolves [domainKey]'s form spec, or an empty list for an unknown key
/// (never throws — mirrors defensive parsing elsewhere in this feature).
List<DomainFieldSpec> domainFormSpecFor(String domainKey) => domainFormSpecs[domainKey] ?? const [];

/// Builds the exact POST body for a domain's create endpoint from the
/// current form [values] (keyed by [DomainFieldSpec.key]). A `null`/absent
/// value is omitted entirely (mirrors the engine's `body.get(x) or None`
/// optional-field handling — sending `null` explicitly is never needed).
/// [DomainFieldType.date] values serialize to a tz-aware ISO8601 UTC string
/// via `DateTime.toUtc().toIso8601String()` (the engine's
/// `datetime.fromisoformat(ts_str.replace("Z", "+00:00"))` parses this
/// directly). Fields with a [DomainFieldSpec.dataKey] nest under one
/// top-level `"data"` object instead of being top-level keys.
Map<String, Object?> buildDomainEntryBody(List<DomainFieldSpec> spec, Map<String, Object?> values) {
  final body = <String, Object?>{};
  final data = <String, Object?>{};
  for (final field in spec) {
    final value = values[field.key];
    if (value == null) continue;
    final encoded = field.type == DomainFieldType.date && value is DateTime
        ? (field.dateOnly ? _plainDate(value) : value.toUtc().toIso8601String())
        : value;
    if (field.dataKey != null) {
      data[field.dataKey!] = encoded;
    } else {
      body[field.key] = encoded;
    }
  }
  if (data.isNotEmpty) body['data'] = data;
  return body;
}

/// `YYYY-MM-DD` from the LOCAL calendar fields — deliberately no timezone
/// conversion. See [DomainFieldSpec.dateOnly].
String _plainDate(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
