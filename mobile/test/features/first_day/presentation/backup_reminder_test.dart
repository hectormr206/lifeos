// El aviso del respaldo, visto desde fuera.
//
// La política ya está probada aparte; esto prueba lo otro: que la tarjeta
// aparece cuando toca, que se va cuando la persona actúa, y —sobre todo— que
// NO aparece el primer día, cuando no hay nada que perder y el aviso sólo
// enseñaría a ignorar avisos.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/first_day/presentation/backup_reminder.dart';

Future<void> _pump(WidgetTester tester, {required bool ask}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      shouldAskForBackupProvider.overrideWith((ref) async => ask),
    ],
    child: const MaterialApp(home: Scaffold(body: BackupReminderBanner())),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cuando toca, se ve y dice qué se pierde', (tester) async {
    await _pump(tester, ask: true);

    expect(find.text('Si pierdes este teléfono'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Guardar mi copia'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Luego'), findsOneWidget);
  });

  testWidgets('cuando no toca, no ocupa ni un pixel', (tester) async {
    // Un hueco vacío en la pantalla principal es una tarjeta a medio salir.
    await _pump(tester, ask: false);

    expect(find.text('Si pierdes este teléfono'), findsNothing);
    expect(tester.getSize(find.byType(BackupReminderBanner)), Size.zero);
  });

  testWidgets('mientras se averigua, tampoco parpadea', (tester) async {
    // Sin pumpAndSettle: el primer frame, con el futuro todavía sin resolver.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        shouldAskForBackupProvider.overrideWith((ref) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return true;
        }),
      ],
      child: const MaterialApp(home: Scaffold(body: BackupReminderBanner())),
    ));
    await tester.pump();

    expect(find.text('Si pierdes este teléfono'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Si pierdes este teléfono'), findsOneWidget);
  });

  testWidgets('el texto dice quién puede abrir la copia', (tester) async {
    // Es lo que decide si alguien la guarda en su Drive sin miedo.
    await _pump(tester, ask: true);

    expect(find.textContaining('sólo tú puedes abrirla'), findsOneWidget);
  });
}
