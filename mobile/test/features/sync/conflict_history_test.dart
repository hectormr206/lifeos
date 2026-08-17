// The conflict history is what makes "el borrado gana" safe to say.
//
// The merge engine keeps one version and discards the other — except it does
// not discard it, it puts it here. If this screen were missing or wrong, the
// delete-dominates rule would stop being "the delete wins and the edit is kept"
// and become "the delete destroys the edit", which is a different promise and a
// much worse one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/domain/sync_conflict.dart';
import 'package:lifeos/features/sync/presentation/conflict_history_screen.dart';

SyncConflict _conflict({
  String label = 'nota que perdió',
  String? origin = 'bbbb',
  int lamport = 7,
}) =>
    SyncConflict(
      uuid: 'u-1',
      losingLamport: lamport,
      losingOrigin: origin,
      losingLabel: label,
      resolvedAt: DateTime(2026, 8, 17),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<SyncConflict> conflicts,
  Map<String, String> nicknames = const {},
  void Function(SyncConflict)? onRestore,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ConflictHistoryScreen(
      conflicts: conflicts,
      nicknamesByUuid: nicknames,
      onRestore: onRestore ?? (_) {},
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a losing revision is listed with what it said', (tester) async {
    await _pump(tester, conflicts: [_conflict(label: 'cita del martes')]);

    expect(find.text('cita del martes'), findsOneWidget);
    expect(find.text('Restaurar'), findsOneWidget);
  });

  testWidgets('the device is named, never shown as a raw uuid', (tester) async {
    await _pump(
      tester,
      conflicts: [_conflict(origin: 'bbbb')],
      nicknames: {'bbbb': 'Pixel de pruebas'},
    );

    expect(find.textContaining('Pixel de pruebas'), findsOneWidget);
    expect(find.textContaining('bbbb'), findsNothing);
  });

  testWidgets('an unknown device falls back to readable words', (tester) async {
    // A 32-character hex string tells the user nothing, and a conflict list
    // that cannot be read is a conflict list nobody opens.
    await _pump(tester, conflicts: [_conflict(origin: 'ffffffffffffffff')]);

    expect(find.textContaining('otro dispositivo'), findsOneWidget);
    expect(find.textContaining('ffffffffffffffff'), findsNothing);
  });

  testWidgets('restoring hands back the exact conflict', (tester) async {
    SyncConflict? restored;
    final c = _conflict(label: 'la buena');
    await _pump(tester, conflicts: [c], onRestore: (x) => restored = x);

    await tester.tap(find.text('Restaurar'));
    await tester.pumpAndSettle();

    expect(restored, same(c));
  });

  testWidgets('empty says what the emptiness MEANS', (tester) async {
    await _pump(tester, conflicts: const []);

    expect(find.text('Sin conflictos'), findsOneWidget);
    // "Nada aquí" would leave the user unsure whether the feature works or
    // simply has nothing to show. It has to say which.
    expect(find.textContaining('no han cambiado lo mismo'), findsOneWidget);
  });

  testWidgets('the header explains that nothing is deleted on its own',
      (tester) async {
    await _pump(tester, conflicts: [_conflict()]);

    expect(find.textContaining('Nunca se borra sola'), findsOneWidget);
  });
}
