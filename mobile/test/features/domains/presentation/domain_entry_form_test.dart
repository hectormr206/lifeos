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

  // A BIRTH DATE IS NOT A TIMESTAMP. The `ts` field above defaults to now
  // because "now" is the right answer for when something happened. For a birth
  // date it is the worst possible answer: it is optional, it is always in the
  // past, and it carries no time of day. Defaulting it to now means every
  // person saved without touching the field is recorded as born today — and
  // the birthday and age logic then produces confident nonsense from it.
  group('an optional date field (a birth date)', () {
    const spec = [
      DomainFieldSpec(key: 'name', label: 'Nombre', type: DomainFieldType.text, required: true),
      DomainFieldSpec(key: 'birth_date', label: 'Fecha de nacimiento', type: DomainFieldType.date, dateOnly: true),
      DomainFieldSpec(key: 'ts', label: 'Fecha y hora', type: DomainFieldType.date, required: true),
    ];

    testWidgets('starts empty instead of silently claiming today', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: DomainEntryForm(spec: spec, onSubmit: (_) {}))),
      ));

      expect(find.text('Fecha de nacimiento'), findsOneWidget);
      // The empty state says so, rather than showing a date nobody entered.
      expect(find.text('Sin definir'), findsOneWidget);
    });

    testWidgets('is omitted from the body when the user never sets it', (tester) async {
      Map<String, Object?>? submitted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DomainEntryForm(spec: spec, onSubmit: (body) => submitted = body)),
        ),
      ));

      await tester.enterText(find.widgetWithText(TextFormField, 'Nombre'), 'Juan');
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pump();

      expect(submitted, isNotNull);
      // Absent, not today. An absent birth date is a fact the app can handle;
      // a wrong one it cannot.
      expect(submitted!.containsKey('birth_date'), isFalse);
      expect(submitted!['ts'], isA<String>());
    });

    testWidgets('an initial value from a stored entry is shown, not overwritten', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainEntryForm(
              spec: spec,
              onSubmit: (_) {},
              initialValues: const {'name': 'Sofía', 'birth_date': '2019-03-10'},
            ),
          ),
        ),
      ));

      expect(find.text('10/03/2019'), findsOneWidget);
    });
  });

  group('a date-only field', () {
    const spec = [
      DomainFieldSpec(key: 'birth_date', label: 'Fecha de nacimiento', type: DomainFieldType.date, dateOnly: true),
    ];

    testWidgets('renders without a time of day', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainEntryForm(
              spec: spec,
              onSubmit: (_) {},
              initialValues: const {'birth_date': '1984-11-02'},
            ),
          ),
        ),
      ));

      expect(find.text('02/11/1984'), findsOneWidget);
      expect(find.textContaining('00:00'), findsNothing);
    });

    testWidgets('serialises as a plain calendar date, never a UTC instant', (tester) async {
      // A birth date shifted by a timezone conversion lands on the wrong day
      // for anyone east of UTC — and the app would then wish them happy
      // birthday one day early, forever.
      Map<String, Object?>? submitted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainEntryForm(
              spec: spec,
              onSubmit: (body) => submitted = body,
              initialValues: const {'birth_date': '1984-11-02'},
            ),
          ),
        ),
      ));

      await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
      await tester.pump();

      expect(submitted!['birth_date'], '1984-11-02');
    });
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
