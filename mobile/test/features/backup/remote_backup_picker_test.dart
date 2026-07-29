// Proves the user can reach an OLDER archive. Recovering from a mistake means
// restoring a copy from before it, so silently taking the newest would hand
// back the very state the user is escaping.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backup/domain/backup_host_diagnosis.dart';
import 'package:lifeos/features/backup/presentation/remote_backup_picker.dart';

final _backups = [
  RemoteBackup(
    name: 'lifeos-20260729-1830.lifeos',
    sizeBytes: 5 * 1024 * 1024,
    modifiedAt: DateTime(2026, 7, 29, 18, 30),
  ),
  RemoteBackup(
    name: 'lifeos-20260720-0900.lifeos',
    sizeBytes: 3 * 1024 * 1024,
    modifiedAt: DateTime(2026, 7, 20, 9, 5),
  ),
];

Future<RemoteBackup?> _open(WidgetTester tester) async {
  RemoteBackup? picked;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          picked = await RemoteBackupPicker.show(context, backups: _backups);
        },
        child: const Text('abrir'),
      ),
    ),
  ));
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('shows every archive by date, not by server filename',
      (tester) async {
    await _open(tester);

    expect(find.text('2026-07-29 18:30'), findsOneWidget);
    expect(find.text('2026-07-20 09:05'), findsOneWidget);
    // The raw name is server bookkeeping; a date is what a user recognises.
    expect(find.textContaining('lifeos-20260729'), findsNothing);
  });

  testWidgets('marks the newest so the usual choice is obvious',
      (tester) async {
    await _open(tester);

    expect(find.textContaining('el más reciente'), findsOneWidget);
  });

  testWidgets('an OLDER archive can actually be chosen', (tester) async {
    await _open(tester);

    await tester.tap(find.text('2026-07-20 09:05'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteBackupPicker), findsNothing);
  });

  testWidgets('cancelling picks nothing', (tester) async {
    await _open(tester);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteBackupPicker), findsNothing);
  });
}
