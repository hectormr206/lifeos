// Proves DomainEntryForm (the ONE reusable, data-driven create-entry form,
// spec: structured-domain-forms) renders each DomainFieldType with the
// matching widget, enforces required + numeric-bounds validation
// client-side, and calls onSubmit with the exact built POST body.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_form_spec.dart';
import 'package:lifeos/features/domains/presentation/domain_entry_form.dart';

const _financeSpec = [
  DomainFieldSpec(
    key: 'kind',
    label: 'Tipo',
    type: DomainFieldType.enumType,
    required: true,
    enumOptions: ['expense', 'income'],
  ),
  DomainFieldSpec(key: 'title', label: 'Título', type: DomainFieldType.text, required: true),
  DomainFieldSpec(key: 'amount', label: 'Monto', type: DomainFieldType.number, required: true, min: 0),
  DomainFieldSpec(key: 'duration_minutes', label: 'Duración', type: DomainFieldType.integer, min: 1, max: 500),
  DomainFieldSpec(key: 'ts', label: 'Fecha y hora', type: DomainFieldType.date, required: true),
];

void main() {
  testWidgets('renders a text field with its label', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (_) {}))),
    ));

    expect(find.text('Título'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3)); // title (text) + amount (number) + duration_minutes (integer)
  });

  testWidgets('renders an integer field as a numeric TextFormField', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (_) {}))),
    ));

    expect(find.text('Duración'), findsOneWidget);
  });

  testWidgets('renders an enum field as a dropdown defaulting to the first option', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (_) {}))),
    ));

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    final dropdown = tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>));
    expect(dropdown.initialValue, 'expense');
  });

  testWidgets('renders a date field with a calendar affordance defaulting to now', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (_) {}))),
    ));

    expect(find.text('Fecha y hora'), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today), findsOneWidget);
  });

  testWidgets('leaving required fields empty blocks submit and shows a validation error', (tester) async {
    Map<String, Object?>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (body) => submitted = body)),
      ),
    ));

    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();

    expect(find.text('Este campo es obligatorio.'), findsWidgets);
    expect(submitted, isNull);
  });

  testWidgets('an amount below the minimum blocks submit with a bounds error', (tester) async {
    Map<String, Object?>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (body) => submitted = body)),
      ),
    ));

    await tester.enterText(find.widgetWithText(TextFormField, 'Título'), 'Café');
    await tester.enterText(find.widgetWithText(TextFormField, 'Monto'), '-5');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();

    expect(find.textContaining('mayor o igual a 0'), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('an out-of-range integer field blocks submit with a bounds error', (tester) async {
    Map<String, Object?>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (body) => submitted = body)),
      ),
    ));

    await tester.enterText(find.widgetWithText(TextFormField, 'Título'), 'Café');
    await tester.enterText(find.widgetWithText(TextFormField, 'Monto'), '50');
    await tester.enterText(find.widgetWithText(TextFormField, 'Duración'), '9999');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();

    expect(find.textContaining('menor o igual a 500'), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('submitting a valid form calls onSubmit with the exact built POST body', (tester) async {
    Map<String, Object?>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (body) => submitted = body)),
      ),
    ));

    await tester.enterText(find.widgetWithText(TextFormField, 'Título'), 'Súper');
    await tester.enterText(find.widgetWithText(TextFormField, 'Monto'), '500');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();

    expect(submitted, isNotNull);
    expect(submitted!['kind'], 'expense');
    expect(submitted!['title'], 'Súper');
    expect(submitted!['amount'], 500.0);
    expect(submitted!['ts'], isA<String>());
    expect(submitted!.containsKey('duration_minutes'), isFalse);
  });

  testWidgets('shows an external error message when errorText is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (_) {}, errorText: 'boom')),
      ),
    ));

    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('disables the Save button and shows a spinner while submitting', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DomainEntryForm(spec: _financeSpec, onSubmit: (_) {}, submitting: true)),
      ),
    ));

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
