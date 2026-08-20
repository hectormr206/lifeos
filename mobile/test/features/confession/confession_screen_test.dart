// The confession screen keeps its promise, or it is worse than not existing.
//
// Someone opening this is about to type the thing they have not said out loud.
// If any of it is written down anywhere, the feature has actively harmed them
// — so the guarantees are tested from two directions: what the screen DOES,
// and what the code is even CAPABLE of.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/confession/presentation/confession_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import 'dart:io';

Widget _app() => const ProviderScope(
      child: MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConfessionScreen(),
      ),
    );

void main() {
  testWidgets('it says what happens to the words BEFORE any are typed',
      (tester) async {
    // Consent that arrives after you have already written it is not consent.
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.textContaining('Nada de esto se guarda'), findsWidgets);
  });

  // What this screen must NOT do is now covered from the other direction, in
  // desahogo_copy_test.dart: it does not define itself by negation at all.
  // The ban on absolving anyone lives in the model's guidance, where it
  // belongs — see confession_test.dart.

  testWidgets('there is a place to write and a way to say it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Decirlo'), findsOneWidget);
  });

  test('the feature CANNOT store anything, by construction', () {
    // The strongest guarantee available without running the app: this feature
    // does not import a store, a repository, a database or the graph, so there
    // is nowhere for the words to go. Tested by reading the source, because
    // "we remembered not to persist it" is a habit and this needs to be a
    // property.
    final sources = Directory('lib/features/confession')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    expect(sources, isNotEmpty, reason: 'the feature moved');

    for (final file in sources) {
      final code = file.readAsStringSync();
      for (final forbidden in const [
        'local_graph_store',
        'graph_providers',
        'shared_preferences',
        'sqflite',
        'chat_notifier',
        'ChatHistoryStore',
      ]) {
        expect(code, isNot(contains(forbidden)),
            reason: '${file.path} can reach $forbidden — a confession must '
                'have nowhere to be written down');
      }
    }
  });
}
