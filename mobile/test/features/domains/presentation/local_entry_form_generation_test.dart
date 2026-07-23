// Proves the ONE generated form (DomainEntryForm) renders any LOCAL entry
// type purely from its config fields (native domain CRUD): typed widgets per
// field, Spanish enum display labels over English wire values, EDIT prefill
// via initialValues, and a typed submit body.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:lifeos/features/domains/presentation/domain_entry_form.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('generates the blood-pressure form from config and submits typed values', (tester) async {
    final bp = localEntryTypeFor('health', 'blood_pressure')!;
    Map<String, Object?>? submitted;

    await tester.pumpWidget(_host(DomainEntryForm(spec: bp.fields, onSubmit: (body) => submitted = body)));

    // Every configured field renders (one form widget for all domains).
    for (final label in ['Sistólica', 'Diastólica', 'Pulso', 'Fecha y hora', 'Notas']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.enterText(find.widgetWithText(TextFormField, 'Sistólica'), '120');
    await tester.enterText(find.widgetWithText(TextFormField, 'Diastólica'), '80');
    await tester.enterText(find.widgetWithText(TextFormField, 'Pulso'), '72');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();

    expect(submitted!['systolic'], 120);
    expect(submitted!['diastolic'], 80);
    expect(submitted!['pulse'], 72);
    expect(submitted!['ts'], isA<String>()); // ISO8601 from the date field
  });

  testWidgets('required + bounds validation comes from config (sleep 0..24 h)', (tester) async {
    final sleep = localEntryTypeFor('health', 'sleep_hours')!;
    var submitCount = 0;

    await tester.pumpWidget(_host(DomainEntryForm(spec: sleep.fields, onSubmit: (_) => submitCount++)));

    // Empty required field blocks submit.
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();
    expect(submitCount, 0);
    expect(find.text('Este campo es obligatorio.'), findsOneWidget);

    // Out-of-bounds blocks too (max 24 from the config).
    await tester.enterText(find.widgetWithText(TextFormField, 'Horas de sueño'), '30');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();
    expect(submitCount, 0);
    expect(find.textContaining('menor o igual a 24'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Horas de sueño'), '7.5');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();
    expect(submitCount, 1);
  });

  testWidgets('enum fields show Spanish labels but keep English wire values', (tester) async {
    final workout = localEntryTypeFor('exercise', 'workout')!;
    Map<String, Object?>? submitted;

    await tester.pumpWidget(_host(DomainEntryForm(spec: workout.fields, onSubmit: (body) => submitted = body)));

    expect(find.text('Caminata'), findsOneWidget); // display label
    expect(find.text('walk'), findsNothing); // wire value never shown

    await tester.tap(find.text('Caminata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carrera').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Duración'), '30');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();

    expect(submitted!['kind'], 'run'); // stored value stays laptop-compatible
    expect(submitted!['duration_minutes'], 30);
  });

  testWidgets('initialValues prefill the form for EDIT (text, number, enum, ISO date)', (tester) async {
    final expense = localEntryTypeFor('finance', 'expense')!;
    Map<String, Object?>? submitted;

    await tester.pumpWidget(_host(DomainEntryForm(
      spec: expense.fields,
      initialValues: {
        'amount': 250.0,
        'category': 'transporte',
        'note': 'gasolina',
        'ts': DateTime(2026, 7, 20, 9).toUtc().toIso8601String(),
      },
      submitLabel: 'Guardar cambios',
      onSubmit: (body) => submitted = body,
    )));

    expect(find.text('250.0'), findsOneWidget);
    expect(find.text('gasolina'), findsOneWidget);
    expect(find.text('transporte'), findsOneWidget);
    expect(find.text('Guardar cambios'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Guardar cambios'));
    await tester.pump();

    expect(submitted!['amount'], 250.0);
    expect(submitted!['category'], 'transporte');
    expect(submitted!['note'], 'gasolina');
    expect(DateTime.parse(submitted!['ts'] as String), DateTime(2026, 7, 20, 9).toUtc());
  });
}
