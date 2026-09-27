// "Con personas reales": get ready before, learn after.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/practice_service.dart';
import 'package:lifeos/features/english/data/real_talk_service.dart';
import 'package:lifeos/features/english/data/word_gloss.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_real_talk_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

class _Saver implements WordSaver {
  final List<(String, String?, SavedContext)> saved = [];
  @override
  Future<void> save({
    required String lemma,
    required String? gloss,
    required SavedContext context,
  }) async => saved.add((lemma, gloss, context));
}

String _reply(String prompt) {
  if (prompt.contains('PHRASE:')) {
    return 'PHRASE: Thanks for your time.\nQUESTION: How much will it cost?';
  }
  if (prompt.contains('que cuesta extra')) return 'It costs extra.';
  if (prompt.contains('el precio')) return 'It is about 2,000 dollars.';
  return 'Sure.';
}

Widget _app({FakeLocalLlmEngine? engine, _Saver? saver}) {
  final model = engine ?? FakeLocalLlmEngine(reply: _reply);
  return ProviderScope(
    overrides: [
      realTalkServiceProvider.overrideWithValue(RealTalkService(model)),
      practiceServiceProvider.overrideWithValue(PracticeService(model)),
      latestPlacementProvider.overrideWith((ref) async => null),
      wordSaverProvider.overrideWith((ref) async => saver ?? _Saver()),
    ],
    child: const MaterialApp(
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: EnglishRealTalkScreen(),
    ),
  );
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Prepare and rephrase follow their own trimmed inputs', (
    tester,
  ) async {
    final engine = FakeLocalLlmEngine(reply: _reply);
    await tester.pumpWidget(_app(engine: engine));
    await tester.pumpAndSettle();
    final situation = find.byKey(const Key('real-talk-situation'));
    final wanted = find.byKey(const Key('real-talk-wanted'));
    final prepare = find.widgetWithText(FilledButton, 'Preparar');
    final rephrase = find.widgetWithText(FilledButton, '¿Cómo lo digo?');
    expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
    expect(tester.widget<FilledButton>(rephrase).onPressed, isNull);

    await tester.enterText(situation, '  ');
    await tester.enterText(wanted, '\n  \n');
    await tester.pump();
    expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
    expect(tester.widget<FilledButton>(rephrase).onPressed, isNull);
    expect(engine.prompts, isEmpty);

    await tester.enterText(situation, 'A call');
    await tester.pump();
    expect(tester.widget<FilledButton>(prepare).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(rephrase).onPressed, isNull);
    await tester.enterText(situation, '\n ');
    await tester.pump();
    expect(tester.widget<FilledButton>(prepare).onPressed, isNull);

    await tester.enterText(wanted, '\n el precio \n  ');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(rephrase).onPressed,
      isNotNull,
      reason: 'rephrasing does not require a situation',
    );
    expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
    await _tapVisible(tester, find.text('¿Cómo lo digo?'));
    expect(engine.prompts, hasLength(1));
    expect(engine.prompts.single, contains('el precio'));
  });

  testWidgets('it says plainly what it is for', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.textContaining('no reemplaza'), findsOneWidget);
  });

  testWidgets('before: phrases and questions, then a rehearsal that opens '
      'with one of those questions', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('real-talk-situation')),
      'Llamada con un cliente',
    );
    await _tapVisible(tester, find.text('Preparar'));

    expect(find.text('Thanks for your time.'), findsOneWidget);
    expect(find.text('How much will it cost?'), findsOneWidget);

    await _tapVisible(tester, find.text('Ensayar la conversación'));

    expect(
      find.text('How much will it cost?'),
      findsOneWidget,
      reason: 'the rehearsal opens with the prepared question',
    );
    expect(find.textContaining('Tu objetivo'), findsOneWidget);
  });

  testWidgets('after: each thing gets its English, and can be kept', (
    tester,
  ) async {
    final saver = _Saver();
    await tester.pumpWidget(_app(saver: saver));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('real-talk-situation')),
      'Llamada con un cliente',
    );
    await tester.enterText(
      find.byKey(const Key('real-talk-wanted')),
      'que cuesta extra\nel precio aproximado',
    );
    await _tapVisible(tester, find.text('¿Cómo lo digo?'));

    final list = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('It is about 2,000 dollars.'),
      100,
      scrollable: list,
    );
    expect(find.text('It is about 2,000 dollars.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('It costs extra.'),
      -100,
      scrollable: list,
    );
    expect(find.text('It costs extra.'), findsOneWidget);

    await _tapVisible(tester, find.text('Guardar para repasar').first);

    final (lemma, gloss, context) = saver.saved.single;
    expect(lemma, 'It costs extra.');
    expect(gloss, 'que cuesta extra');
    expect(context.sentence, 'It costs extra.');
  });

  testWidgets('a model that cannot help is said', (tester) async {
    await tester.pumpWidget(
      _app(engine: FakeLocalLlmEngine(generateShouldFail: true)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('real-talk-situation')),
      'Una llamada',
    );
    await _tapVisible(tester, find.text('Preparar'));

    expect(find.textContaining('No se pudo esta vez'), findsOneWidget);
  });
}
