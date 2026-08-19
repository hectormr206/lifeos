import 'package:flutter/material.dart';

import '../domain/domain_form_spec.dart';

/// The ONE reusable, data-driven create-entry form (spec:
/// structured-domain-forms). Renders any domain's fields purely from its
/// [DomainFieldSpec] list — text -> `TextFormField`, number/integer ->
/// bounds-validated numeric `TextFormField`, enumType ->
/// `DropdownButtonFormField`, date -> a date/time picker button defaulting
/// to now. NO per-domain widget code, ever — mirrors `DomainDescriptor`'s
/// registry philosophy (design D2) and `SettingsScreen`'s schema-driven
/// field-tile pattern.
class DomainEntryForm extends StatefulWidget {
  const DomainEntryForm({
    required this.spec,
    required this.onSubmit,
    this.submitting = false,
    this.errorText,
    this.initialValues,
    this.submitLabel = 'Guardar',
    super.key,
  });

  final List<DomainFieldSpec> spec;

  /// Prefill for EDIT flows (native domain CRUD): field key → stored value.
  /// Date fields accept a [DateTime] or an ISO8601 string; missing keys keep
  /// the create defaults (now / first enum option / empty text).
  final Map<String, Object?>? initialValues;

  /// Save-button caption (create vs edit reuse the same widget).
  final String submitLabel;

  /// Called with the exact built POST body ([buildDomainEntryBody]'s
  /// output) once the form validates successfully.
  final void Function(Map<String, Object?> body) onSubmit;

  /// Disables the Save button and shows a spinner while a submit is
  /// in-flight — set by the caller (mirrors `SettingsScreen`'s `state.saving`).
  final bool submitting;

  /// A server-side error surfaced by the caller (e.g. a 400 from the
  /// create endpoint) — shown below the Save button.
  final String? errorText;

  @override
  State<DomainEntryForm> createState() => _DomainEntryFormState();
}

class _DomainEntryFormState extends State<DomainEntryForm> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, Object?> _values = {};
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    final initial = widget.initialValues ?? const <String, Object?>{};
    for (final field in widget.spec) {
      final preset = initial[field.key];
      switch (field.type) {
        case DomainFieldType.date:
          // "Now" is the right default for a REQUIRED timestamp — when the
          // thing happened. For an optional date it is a claim the user never
          // made, and one they would have to notice to correct.
          _values[field.key] = _asDateTime(preset) ?? (field.required ? DateTime.now() : null);
        case DomainFieldType.enumType:
          _values[field.key] = (preset is String && field.enumOptions!.contains(preset))
              ? preset
              : field.enumOptions!.first;
        case DomainFieldType.text:
        case DomainFieldType.number:
        case DomainFieldType.integer:
          _controllers[field.key] = TextEditingController(text: preset?.toString() ?? '');
      }
    }
  }

  /// Accepts the two shapes an initial date value can arrive in: a [DateTime]
  /// (in-memory) or the ISO8601 string a stored entry carries.
  static DateTime? _asDateTime(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value)?.toLocal();
    return null;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _requiredError(DomainFieldSpec field, String text) {
    if (field.required && text.trim().isEmpty) return 'Este campo es obligatorio.';
    return null;
  }

  String? _numericValidator(DomainFieldSpec field, String text) {
    final requiredError = _requiredError(field, text);
    if (requiredError != null) return requiredError;
    if (text.trim().isEmpty) return null;
    final parsed = field.type == DomainFieldType.integer ? int.tryParse(text.trim()) : num.tryParse(text.trim());
    if (parsed == null) return 'Debe ser un número.';
    if (field.min != null && parsed < field.min!) return 'Debe ser mayor o igual a ${field.min}.';
    if (field.max != null && parsed > field.max!) return 'Debe ser menor o igual a ${field.max}.';
    return null;
  }

  void _submit() {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;
    for (final field in widget.spec) {
      final controller = _controllers[field.key];
      if (controller == null) continue;
      final text = controller.text.trim();
      switch (field.type) {
        case DomainFieldType.text:
          _values[field.key] = text.isEmpty ? null : text;
        case DomainFieldType.number:
          _values[field.key] = text.isEmpty ? null : num.tryParse(text);
        case DomainFieldType.integer:
          _values[field.key] = text.isEmpty ? null : int.tryParse(text);
        case DomainFieldType.date:
        case DomainFieldType.enumType:
          break;
      }
    }
    widget.onSubmit(buildDomainEntryBody(widget.spec, _values));
  }

  Future<void> _pickDate(DomainFieldSpec field) async {
    final current = _values[field.key] as DateTime? ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      // A birth date is decades in the past. A 2000 floor silently excludes
      // most adults from a feature whose whole point is remembering people.
      firstDate: field.dateOnly ? DateTime(1900) : DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;

    // Nobody knows a friend's daughter's time of birth, and asking makes the
    // field feel broken.
    if (field.dateOnly) {
      setState(() => _values[field.key] = DateTime(date.year, date.month, date.day));
      return;
    }

    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (!mounted) return;
    setState(() {
      _values[field.key] = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? current.hour,
        time?.minute ?? current.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      // Re-validate as the user types, but only AFTER they have touched the
      // field. Seen on the test Pixel: with 118 and 78 already entered, both
      // "Este campo es obligatorio." messages were still on screen, because
      // the form only re-validated on the next save — the app telling someone
      // off for something they had already fixed. The default (disabled) also
      // has the opposite failure: eager validation would greet a first-time
      // user with a wall of red before they typed anything.
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final field in widget.spec)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: _fieldWidget(field)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.submitting ? null : _submit,
            icon: widget.submitting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(widget.submitLabel),
          ),
          if (widget.errorText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(widget.errorText!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }

  Widget _fieldWidget(DomainFieldSpec field) {
    switch (field.type) {
      case DomainFieldType.enumType:
        return DropdownButtonFormField<String>(
          initialValue: _values[field.key] as String?,
          decoration: InputDecoration(labelText: field.label, border: const OutlineInputBorder()),
          items: [
            for (final option in field.enumOptions!)
              DropdownMenuItem(value: option, child: Text(field.enumLabels?[option] ?? option)),
          ],
          onChanged: (value) => setState(() => _values[field.key] = value),
        );
      case DomainFieldType.date:
        final current = _values[field.key] as DateTime?;
        final text = current == null
            ? 'Sin definir'
            : (field.dateOnly ? _formatDateOnly(current) : _formatDate(current));
        return InkWell(
          onTap: () => _pickDate(field),
          child: InputDecorator(
            decoration: InputDecoration(labelText: field.label, border: const OutlineInputBorder()),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: current == null
                        ? TextStyle(color: Theme.of(context).hintColor)
                        : null,
                  ),
                ),
                const Icon(Icons.calendar_today),
              ],
            ),
          ),
        );
      case DomainFieldType.text:
        return TextFormField(
          controller: _controllers[field.key],
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
            suffixText: field.unitHint,
          ),
          validator: (text) => _requiredError(field, text ?? ''),
        );
      case DomainFieldType.number:
      case DomainFieldType.integer:
        return TextFormField(
          controller: _controllers[field.key],
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
            suffixText: field.unitHint,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          validator: (text) => _numericValidator(field, text ?? ''),
        );
    }
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }

  /// No time of day, and no `toLocal()` — a date-only value carries local
  /// calendar fields already, and converting it can move it a day.
  String _formatDateOnly(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year}';
  }
}
