// Proves the passphrase prompt refuses the two mistakes that cannot be undone
// later: an empty phrase, and a mistyped one confirmed only once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backup/presentation/passphrase_dialog.dart';

Future<String?> _open(WidgetTester tester, {required bool confirm}) async {
  String? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          result = await PassphraseDialog.show(
            context,
            title: 'Frase',
            actionLabel: 'Continuar',
            confirm: confirm,
          );
        },
        child: const Text('abrir'),
      ),
    ),
  ));
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('sealing warns that the phrase is the only way in',
      (tester) async {
    await _open(tester, confirm: true);

    expect(find.textContaining('no hay forma de recuperarlo'), findsOneWidget);
  });

  testWidgets('refuses an empty phrase instead of sealing with nothing',
      (tester) async {
    await _open(tester, confirm: true);

    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();

    expect(find.text('Escribí una frase.'), findsOneWidget);
    // Still open: nothing was returned to the caller.
    expect(find.byType(PassphraseDialog), findsOneWidget);
  });

  testWidgets('refuses two phrases that do not match', (tester) async {
    await _open(tester, confirm: true);

    await tester.enterText(find.byType(TextField).first, 'caballo correcto');
    await tester.enterText(find.byType(TextField).last, 'caballo incorrecto');
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();

    expect(find.text('Las dos frases no coinciden.'), findsOneWidget);
    expect(find.byType(PassphraseDialog), findsOneWidget);
  });

  testWidgets('accepts a phrase typed the same twice', (tester) async {
    await _open(tester, confirm: true);

    await tester.enterText(find.byType(TextField).first, 'caballo correcto');
    await tester.enterText(find.byType(TextField).last, 'caballo correcto');
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();

    expect(find.byType(PassphraseDialog), findsNothing);
  });

  testWidgets('opening an archive asks once — a wrong phrase fails harmlessly',
      (tester) async {
    await _open(tester, confirm: false);

    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('no hay forma de recuperarlo'), findsNothing);
  });

  testWidgets('the phrase can be revealed while typing', (tester) async {
    await _open(tester, confirm: true);

    // Typing an unrecoverable secret blind is a trap; the toggle must exist.
    expect(find.byTooltip('Mostrar'), findsOneWidget);
    await tester.tap(find.byTooltip('Mostrar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ocultar'), findsOneWidget);
  });
}
