// "Sonidos para practicar": the one or two sound tips under a recording.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/pron_feedback.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_sound_tips.dart';
import 'package:lifeos/l10n/app_localizations.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

const _ready = PronModelStatus(PronModelState.ready);

void main() {
  testWidgets('a tip says the sound, how to make it, and what was heard',
      (tester) async {
    await tester.pumpWidget(_app(SoundTipsSection(
      status: _ready,
      tips: const [
        SoundTip(pattern: SoundPattern.shortI, words: ['ship', 'sit'],
            expected: 'ɪ', heard: 'i'),
      ],
      onDownload: () {},
    )));

    expect(find.text('Sonidos para practicar'), findsOneWidget);
    expect(find.text('La i corta de ship'), findsOneWidget);
    expect(find.textContaining('«ship» no es «sheep»'), findsOneWidget);
    expect(find.text('En ship, sit: se oyó [i] en lugar de [ɪ].'), findsOneWidget);
    expect(find.textContaining('Orientativo'), findsOneWidget);
  });

  testWidgets('a sound left out is said as not heard', (tester) async {
    await tester.pumpWidget(_app(SoundTipsSection(
      status: _ready,
      tips: const [
        SoundTip(pattern: SoundPattern.finalSound, words: ['cat'],
            expected: 't', heard: ''),
      ],
      onDownload: () {},
    )));

    expect(find.text('En cat: no se oyó [t].'), findsOneWidget);
  });

  testWidgets('every pattern has its own words, in both languages',
      (tester) async {
    for (final locale in const [Locale('es'), Locale('en')]) {
      final l10n = await AppLocalizations.delegate.load(locale);
      final titles = {
        for (final p in SoundPattern.values) soundTipTitle(l10n, p),
      };
      final hows = {for (final p in SoundPattern.values) soundTipHow(l10n, p)};
      expect(titles, hasLength(SoundPattern.values.length));
      expect(hows, hasLength(SoundPattern.values.length));
    }
  });

  testWidgets('nothing to practise is said too', (tester) async {
    await tester.pumpWidget(_app(
        SoundTipsSection(status: _ready, tips: const [], onDownload: () {})));

    expect(find.text('Ningún sonido que practicar en esta frase.'),
        findsOneWidget);
  });

  testWidgets('while listening it says so', (tester) async {
    await tester.pumpWidget(_app(SoundTipsSection(
        status: _ready, tips: null, working: true, onDownload: () {})));

    expect(find.text('Escuchando los sonidos…'), findsOneWidget);
  });

  testWidgets('without the model: an offer to download it, with its size',
      (tester) async {
    var asked = 0;
    await tester.pumpWidget(_app(SoundTipsSection(
      status: const PronModelStatus(PronModelState.absent),
      tips: null,
      onDownload: () => asked++,
    )));

    await tester.tap(find.textContaining('71 MB'));
    expect(asked, 1);
  });

  testWidgets('downloading shows progress; a failure offers a retry',
      (tester) async {
    await tester.pumpWidget(_app(SoundTipsSection(
      status: const PronModelStatus(PronModelState.downloading, 0.42),
      tips: null,
      onDownload: () {},
    )));
    expect(find.textContaining('42%'), findsOneWidget);

    await tester.pumpWidget(_app(SoundTipsSection(
      status: const PronModelStatus(PronModelState.failed),
      tips: null,
      onDownload: () {},
    )));
    expect(find.textContaining('No se pudo descargar'), findsOneWidget);
    expect(find.textContaining('71 MB'), findsOneWidget);
  });

  testWidgets('while the model is being checked, nothing shows', (tester) async {
    await tester.pumpWidget(_app(SoundTipsSection(
      status: const PronModelStatus(PronModelState.checking),
      tips: null,
      onDownload: () {},
    )));

    expect(find.byType(Text), findsNothing);
  });
}
