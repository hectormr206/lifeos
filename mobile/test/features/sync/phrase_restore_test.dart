// Joining a device set that already exists.
//
// This suite exists because the feature shipped without it. Every path in the
// UI generated a NEW phrase, so a second device could only ever create its own
// key — two devices, both reporting "sincronización activa", neither able to
// read a single envelope the other wrote. Nothing failed; nothing arrived.
//
// So the rule these tests pin: a device can be told an EXISTING phrase, the
// checksum decides whether it is accepted, and a rejected phrase leaves the
// device exactly as it was.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/sync/phrase.dart';
import 'package:lifeos/features/sync/data/sync_key_store.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:lifeos/features/sync/domain/sync_enablement.dart';
import 'package:lifeos/features/sync/presentation/phrase_restore_screen.dart';

class FakeSyncKeyStore implements SyncKeyStore {
  List<int>? _entropy;

  @override
  Future<List<int>?> readEntropy() async => _entropy;

  @override
  Future<void> writeEntropy(List<int> entropy) async => _entropy = entropy;

  @override
  Future<void> clear() async => _entropy = null;
}

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: child));

void main() {
  group('a second device joins with the phrase from the first', () {
    testWidgets('a valid phrase is accepted and handed back', (tester) async {
      final ceremony = PhraseCeremony.generate();
      String? restored;

      await _pump(
        tester,
        PhraseRestoreScreen(
          onRestore: (phrase) async => restored = phrase,
          onCancel: () {},
        ),
      );

      await tester.enterText(find.byType(TextField), ceremony.mnemonic);
      await tester.tap(find.text('Activar sincronización'));
      await tester.pumpAndSettle();

      expect(normalisePhrase(restored!), normalisePhrase(ceremony.mnemonic));
    });

    testWidgets('a mistyped phrase is refused and explained', (tester) async {
      var called = false;

      await _pump(
        tester,
        PhraseRestoreScreen(
          onRestore: (_) async => called = true,
          onCancel: () {},
        ),
      );

      // Twelve real words whose checksum cannot hold. NOT "one word swapped for
      // zoo": a wrong last word lands on a valid 4-bit checksum one time in
      // sixteen, and a test that fails 1-in-16 gets deleted instead of fixed.
      await tester.enterText(
        find.byType(TextField),
        List.filled(kWordCount, 'abandon').join(' '),
      );
      await tester.tap(find.text('Activar sincronización'));
      await tester.pumpAndSettle();

      expect(called, isFalse, reason: 'a bad phrase must never reach storage');
      expect(find.textContaining('no es válida'), findsOneWidget);
    });

    testWidgets('extra spacing and capitals do not defeat a good phrase',
        (tester) async {
      // People retype from paper. Leading spaces and a capitalised first word
      // are what real transcription looks like, and rejecting them teaches the
      // user their correct phrase is wrong.
      final ceremony = PhraseCeremony.generate();
      final words = ceremony.words;
      final messy = '  ${words.first.toUpperCase()}   '
          '${words.skip(1).join('  ')}  ';
      String? restored;

      await _pump(
        tester,
        PhraseRestoreScreen(
          onRestore: (phrase) async => restored = phrase,
          onCancel: () {},
        ),
      );

      await tester.enterText(find.byType(TextField), messy);
      await tester.tap(find.text('Activar sincronización'));
      await tester.pumpAndSettle();

      expect(restored, isNotNull);
      expect(
        await () async {
          final store = FakeSyncKeyStore();
          await SyncEnablement(store: store).restore(restored!);
          return store.readEntropy();
        }(),
        ceremony.entropy,
        reason: 'the messy transcription must derive the ORIGINAL key, not a '
            'different one that merely passes the checksum',
      );
    });

    testWidgets('an empty field is refused without pretending to work',
        (tester) async {
      var called = false;

      await _pump(
        tester,
        PhraseRestoreScreen(
          onRestore: (_) async => called = true,
          onCancel: () {},
        ),
      );

      await tester.tap(find.text('Activar sincronización'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
    });

    testWidgets('it never offers to paste from the clipboard', (tester) async {
      // Same reason the ceremony has no copy button: the clipboard is readable
      // by every app on the device and survives in clipboard history. Offering
      // paste here would undo the discipline the other screen imposes.
      await _pump(
        tester,
        PhraseRestoreScreen(onRestore: (_) async {}, onCancel: () {}),
      );

      expect(find.textContaining('Pegar'), findsNothing);
      expect(find.textContaining('portapapeles'), findsNothing);
    });
  });
}
