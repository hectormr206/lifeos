/// DETERMINISTIC bare-scale dictation parser (crown-jewel structured capture,
/// third half).
///
/// Dart port of the laptop `lifeos/src/lifeos/health/ingestion.py`
/// `_try_bare_scale_sequence`, which the first port carried as a deferred TODO.
/// The user reads out ONLY the numbers their smart scale cycles through, with
/// no labels — "15.5, 7, 36.9, 1395, 23.4, 59.8" — and each is assigned to a
/// metric by its plausible RANGE, not by the order the user happened to start
/// dictating from.
///
/// PRECISION-FIRST (never-corrupt-user-data): the cycle is rotated and a
/// rotation matches only when EVERY number fits its slot. Exactly one matching
/// rotation is required; on zero or two or more this yields null and the
/// labeled parsers keep ownership. Guessing which number is body fat and which
/// is BMI would write a coin flip into a health record, which is worse than
/// capturing nothing.
///
/// PURE: the scale order is injected, never read from config here, so tests pin
/// it and the caller supplies whatever the user's scale actually reports.
library;

/// Canonical order of a typical smart-scale cycle. Overridable per call.
const List<String> kDefaultScaleSequence = <String>[
  'weight',
  'fat',
  'visceral',
  'muscle',
  'bmr',
  'bmi',
];

/// slot → (output field, min, max, must be integer-valued)
const Map<String, _SlotSpec> _slotSpecs = <String, _SlotSpec>{
  'weight': _SlotSpec('weight_kg', 30.0, 250.0, false),
  'fat': _SlotSpec('body_fat_pct', 3.0, 60.0, false),
  'visceral': _SlotSpec('visceral_fat', 1.0, 30.0, true),
  'muscle': _SlotSpec('muscle_pct', 15.0, 60.0, false),
  'bmr': _SlotSpec('basal_metabolic_rate', 800.0, 4000.0, false),
  'bmi': _SlotSpec('bmi', 10.0, 60.0, false),
};

class _SlotSpec {
  const _SlotSpec(this.field, this.min, this.max, this.integerOnly);
  final String field;
  final double min;
  final double max;
  final bool integerOnly;
}

/// A recognised scale reading: the typed fields plus an auditable title.
class ScaleReading {
  const ScaleReading({required this.fields, required this.title});

  /// Keyed by the `body_composition` entry-type field keys.
  final Map<String, double> fields;

  /// Human summary in dictation order, e.g.
  /// "báscula: grasa 15.5%, visceral 7, músculo 36.9%, RM 1395, IMC 23.4,
  /// peso 59.8" — shown in the capture ack so the user can verify the
  /// assignment rather than trust it.
  final String title;
}

final RegExp _numberRe = RegExp(r'\d+(?:[.,]\d+)?');

/// Unit words a person sprinkles while dictating. Removed before checking that
/// nothing but numbers and separators remain.
final RegExp _unitRe = RegExp(
  r'\b(?:kg|kilos?|kcal|kilocalor[ií]as?)\b|%',
  caseSensitive: false,
);

/// Parse a bare-numbers scale dictation, or null when it is not one.
ScaleReading? parseScaleSequence(
  String text, {
  List<String> sequence = kDefaultScaleSequence,
}) {
  if (text.trim().isEmpty) return null;

  final matches = _numberRe.allMatches(text).toList();
  // Fewer than four is too ambiguous — and two or three bare numbers are a
  // blood-pressure reading, which owns that shape. More than seven is not a
  // scale cycle.
  if (matches.length < 4 || matches.length > 7) return null;

  // Anything left after removing numbers, units and separators means the
  // message contains real words, so it is prose the labeled parsers own.
  var leftover = text.replaceAll(_numberRe, ' ');
  leftover = leftover.replaceAll(_unitRe, ' ');
  final tokens = leftover
      .replaceAll(RegExp(r'[\s,.;]+'), ' ')
      .trim()
      .toLowerCase()
      .split(' ')
      .where((t) => t.isNotEmpty);
  if (tokens.any((t) => t != 'y')) return null;

  final numbers = <double>[];
  for (final m in matches) {
    final parsed = double.tryParse(m.group(0)!.replaceAll(',', '.'));
    if (parsed == null) return null;
    numbers.add(parsed);
  }

  final n = sequence.length;
  List<String>? matched;
  for (var offset = 0; offset < n; offset++) {
    final slots = <String>[
      for (var i = 0; i < numbers.length; i++) sequence[(offset + i) % n],
    ];
    // A run long enough to wrap onto a slot it already used cannot be read
    // unambiguously.
    if (slots.toSet().length != slots.length) continue;

    var ok = true;
    for (var i = 0; i < slots.length; i++) {
      final spec = _slotSpecs[slots[i]];
      final v = numbers[i];
      if (spec == null ||
          v < spec.min ||
          v > spec.max ||
          (spec.integerOnly && v != v.roundToDouble())) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    // A second plausible rotation means the dictation is genuinely ambiguous.
    if (matched != null) return null;
    matched = slots;
  }
  if (matched == null) return null;

  final fields = <String, double>{};
  final parts = <String>[];
  for (var i = 0; i < matched.length; i++) {
    final slot = matched[i];
    final v = numbers[i];
    fields[_slotSpecs[slot]!.field] = v;
    parts.add(_label(slot, v));
  }
  return ScaleReading(fields: fields, title: 'báscula: ${parts.join(', ')}');
}

String _label(String slot, double v) {
  final n = _trim(v);
  switch (slot) {
    case 'weight':
      return 'peso $n';
    case 'fat':
      return 'grasa $n%';
    case 'visceral':
      return 'visceral $n';
    case 'muscle':
      return 'músculo $n%';
    case 'bmr':
      return 'RM ${v.round()}';
    case 'bmi':
      return 'IMC $n';
  }
  return '$slot $n';
}

/// 59.8 → "59.8", 7.0 → "7" (matches the laptop's %g formatting).
String _trim(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
