// The Desahogo screen says what it IS FOR.
//
// Asked for, after opening it: "podríamos hacer algo mejor sin decir que no
// es... guiarnos más en lo que sí es, que es alguien que te escuche... no
// tienes que colocar texto de para lo que no es este Desahogo, tienes que
// decirle para qué SÍ es".
//
// He is right, and the reason is not only tone. A screen that opens by listing
// what it is not makes someone defend themselves before they have said
// anything — and the person who most needs this is the least likely to push
// past a paragraph of disclaimers.
//
// The guarantees do not go away; they move. "Nothing is stored" stays, because
// that is a promise about what happens to their words and they need it BEFORE
// they type. What goes is the theological disclaimer: the model is still
// forbidden from absolving anyone (see confession.dart), it just no longer
// leads with it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/confession/presentation/confession_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

Widget _app() => const ProviderScope(
      child: MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConfessionScreen(),
      ),
    );

void main() {
  testWidgets('it opens by saying someone is listening', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.textContaining('escuch'), findsWidgets,
        reason: 'the one thing this space offers is not on screen');
  });

  testWidgets('it does not define itself by what it is not', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();

    for (final negation in ['No es una confesión religiosa', 'no perdona',
      'no absuelve', 'no le corresponde']) {
      expect(find.textContaining(negation), findsNothing,
          reason: '"$negation" makes someone defend themselves before they '
              'have said anything');
    }
  });

  testWidgets('the promise about the words is still made UP FRONT',
      (tester) async {
    // This one stays: consent that arrives after you have already written it
    // is not consent.
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.textContaining('Nada de esto se guarda'), findsWidgets);
  });

  testWidgets('both ways in are offered: writing and speaking', (tester) async {
    // "Muchas veces te gustaría platicarlo con alguien por medio de la voz."
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });
}
