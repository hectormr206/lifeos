// Choosing a practice, and writing with a short review.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/practice_service.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/presentation/english_practice_screen.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

Widget _app({EnglishGoal? goal, String Function(String)? reply}) =>
    ProviderScope(
      overrides: [
        englishGoalProvider.overrideWith((ref) async => goal),
        practiceServiceProvider.overrideWithValue(PracticeService(
            FakeLocalLlmEngine(reply: reply ?? (_) => 'NO MISTAKES'))),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishPracticeScreen(),
      ),
    );

Future<void> _write(WidgetTester tester, String text) async {
  await tester.tap(find.text('Propuesta para un cliente'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
  // Below the text field: scroll to it, or the tap lands outside the screen.
  await tester.ensureVisible(find.text('Revisar'));
  await tester.tap(find.text('Revisar'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('without a goal it asks for one first', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.textContaining('Primero elige'), findsOneWidget);
  });

  testWidgets('the goal decides what there is to practise', (tester) async {
    await tester.pumpWidget(_app(goal: EnglishGoal.work));
    await tester.pumpAndSettle();

    expect(find.text('Propuesta para un cliente'), findsOneWidget);
    expect(find.text('Correo a la escuela'), findsNothing);
  });

  testWidgets('writing: the task is in English, and a review shows the fix',
      (tester) async {
    await tester.pumpWidget(_app(
      goal: EnglishGoal.work,
      reply: (_) => 'WRONG: I can to make it.\n'
          'RIGHT: I can make it.\n'
          'WHY: Después de "can" no va "to".',
    ));
    await tester.pumpAndSettle();

    await _write(tester, 'I can to make it.');

    expect(find.textContaining('bakery'), findsOneWidget,
        reason: 'reading the task is practice too');
    expect(find.text('I can make it.'), findsOneWidget);
    expect(find.textContaining('no va "to"'), findsOneWidget);
  });

  testWidgets('no mistakes is said as good news', (tester) async {
    await tester.pumpWidget(_app(goal: EnglishGoal.work));
    await tester.pumpAndSettle();

    await _write(tester, 'I can build your website in three weeks.');

    expect(find.textContaining('Sin errores importantes'), findsOneWidget);
  });

  testWidgets('a review that could not be done is said, not faked',
      (tester) async {
    await tester.pumpWidget(
        _app(goal: EnglishGoal.work, reply: (_) => 'Great job!'));
    await tester.pumpAndSettle();

    await _write(tester, 'Hello.');

    expect(find.textContaining('No se pudo revisar'), findsOneWidget);
  });

  testWidgets('nothing written, nothing to review', (tester) async {
    await tester.pumpWidget(_app(goal: EnglishGoal.work));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Propuesta para un cliente'));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
        find.ancestor(of: find.text('Revisar'), matching: find.byType(FilledButton)));
    expect(button.onPressed, isNull);
  });
}
