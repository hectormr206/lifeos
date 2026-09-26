// Reading aloud: listen, say it, see which words came through.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/audio_recorder_gateway.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/english/data/passage_speaker.dart';
import 'package:lifeos/features/english/data/pron_model.dart';
import 'package:lifeos/features/english/data/pronunciation_coach.dart';
import 'package:lifeos/features/english/domain/pron_lexicon.dart';
import 'package:lifeos/features/english/data/recordings_repository.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_speak_screen.dart';
import 'package:lifeos/features/stt/domain/speech_to_text.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../support/fake_speech.dart';

class _FakeRecorder implements AudioRecorderGateway {
  _FakeRecorder({this.allowed = true});

  final bool allowed;
  bool recording = false;

  @override
  Future<bool> hasPermission() async => allowed;

  @override
  Future<String> start() async {
    recording = true;
    return '/tmp/raw.wav';
  }

  @override
  Future<String?> stop() async {
    recording = false;
    return '/sealed/voice-1.wav.enc';
  }

  @override
  Future<void> cancel() async => recording = false;

  @override
  Future<bool> isRecording() async => recording;
}

class _FakeStt implements SpeechToText {
  _FakeStt(this.reply);

  final String Function() reply;
  final List<String> languages = [];

  @override
  Future<String> transcribe(String wavPath, {required String languageCode}) async {
    languages.add(languageCode);
    return reply();
  }
}

class _FakeArchive implements RecordingArchive {
  final List<Recording> saved = [];

  @override
  Future<void> save(Recording recording) async => saved.add(recording);

  @override
  Future<List<Recording>> all() async => saved;
}

class _Phones implements PhoneRecognizer {
  _Phones(this.ipa, {this.broken = false});
  final String ipa;
  final bool broken;
  final List<String> paths = [];

  @override
  Future<String> phones(String recordingPath) async {
    paths.add(recordingPath);
    if (broken) throw Exception('native failure');
    return ipa;
  }
}

class _PronGateway implements PronModelGateway {
  _PronGateway({this.installed = false});
  bool installed;

  @override
  Future<PronModelPaths?> installedModel() async =>
      installed ? const PronModelPaths(model: 'm', tokens: 't') : null;

  @override
  Future<PronModelPaths> download({void Function(double progress)? onProgress}) async {
    installed = true;
    return const PronModelPaths(model: 'm', tokens: 't');
  }
}

final _lexicon = PronLexicon.parse([
  'dogs D AA1 G Z',
  'sniff S N IH1 F',
  'the DH AH0',
  'ground G R AW1 N D',
  'every EH1 V R IY0',
  'day D EY1',
].join('\n'));

/// "Dogs sniff the ground every day." with sniff as "sneef", every as "ebry".
const _accented = 'dɑgzsnifðəgɹaʊndɛbɹideɪ';

const _passage = 'Dogs sniff the ground every day. They sleep a lot at night.';

Widget _app({
  _FakeRecorder? recorder,
  _FakeStt? stt,
  _FakeArchive? archive,
  FakeSynth? synth,
  _PronGateway? pron,
  _Phones? phones,
}) =>
    ProviderScope(
      overrides: [
        pronModelGatewayProvider.overrideWithValue(pron ?? _PronGateway()),
        pronunciationCoachProvider.overrideWithValue(
            PronunciationCoach(phones ?? _Phones(''), () async => _lexicon)),
        audioRecorderGatewayProvider.overrideWithValue(recorder ?? _FakeRecorder()),
        speechToTextProvider
            .overrideWithValue(stt ?? _FakeStt(() => 'dogs sniff the ground every day')),
        recordingArchiveProvider.overrideWith((ref) async => archive ?? _FakeArchive()),
        installedEnglishVoicesProvider.overrideWith((ref) async =>
            const {'en_US-lessac': TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd')}),
        passageSpeakerProvider.overrideWithValue(PassageSpeaker(
            synthesizer: synth ?? FakeSynth(), playback: FakePlayback())),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishSpeakScreen(text: _passage, source: 'simple.wikipedia.org/Dog'),
      ),
    );

Future<void> _recordOnce(WidgetTester tester) async {
  await tester.tap(find.text('Grabar'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Terminar'));
  await tester.pumpAndSettle();
}

void main() {
  test('practice sentences are the ones worth reading aloud', () {
    expect(practiceSentences('Hi. Dogs sniff the ground every day. Ok.'),
        ['Dogs sniff the ground every day.']);
  });

  testWidgets('saying it right shows it was understood, and keeps it',
      (tester) async {
    final archive = _FakeArchive();
    final stt = _FakeStt(() => 'dogs sniff the ground every day');
    await tester.pumpWidget(_app(archive: archive, stt: stt));
    await tester.pumpAndSettle();

    expect(find.text('Dogs sniff the ground every day.'), findsOneWidget);
    await _recordOnce(tester);

    expect(find.textContaining('100%'), findsOneWidget);
    expect(stt.languages.single, 'en', reason: 'Whisper listens for English');
    final saved = archive.saved.single;
    expect(saved.intelligibility, 1.0);
    expect(saved.audioPath, '/sealed/voice-1.wav.enc');
    expect(saved.source, 'simple.wikipedia.org/Dog');
  });

  testWidgets('a word not understood is marked and the score drops',
      (tester) async {
    await tester.pumpWidget(
        _app(stt: _FakeStt(() => 'dogs sleep the ground every day')));
    await tester.pumpAndSettle();

    await _recordOnce(tester);

    expect(find.textContaining('83%'), findsOneWidget);
    expect(find.textContaining('dogs sleep'), findsOneWidget,
        reason: 'what was heard is shown');
  });

  testWidgets('with the sound model, the sounds to practise show up',
      (tester) async {
    final phones = _Phones(_accented);
    await tester.pumpWidget(
        _app(pron: _PronGateway(installed: true), phones: phones));
    await tester.pumpAndSettle();

    await _recordOnce(tester);

    expect(phones.paths, ['/sealed/voice-1.wav.enc'],
        reason: 'it listens to the same sealed recording');
    await tester.scrollUntilVisible(find.text('La v de very'), 100);
    expect(find.text('La i corta de ship'), findsOneWidget);
    expect(find.textContaining('En sniff'), findsOneWidget);
  });

  testWidgets('downloading the model analyses the recording just made',
      (tester) async {
    final pron = _PronGateway();
    await tester.pumpWidget(_app(pron: pron, phones: _Phones(_accented)));
    await tester.pumpAndSettle();
    await _recordOnce(tester);

    await tester.scrollUntilVisible(find.textContaining('71 MB'), 100);
    await tester.tap(find.textContaining('71 MB'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('La i corta de ship'), 100);
    expect(find.text('La i corta de ship'), findsOneWidget);
  });

  testWidgets('if the sound analysis fails, the rest of the result stands',
      (tester) async {
    await tester.pumpWidget(_app(
        pron: _PronGateway(installed: true), phones: _Phones('', broken: true)));
    await tester.pumpAndSettle();

    await _recordOnce(tester);

    expect(find.textContaining('100%'), findsOneWidget);
    expect(find.text('Sonidos para practicar'), findsNothing);
  });

  testWidgets('"Escuchar" without an English voice says so, not silence',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        pronModelGatewayProvider.overrideWithValue(_PronGateway()),
        installedEnglishVoicesProvider
            .overrideWith((ref) async => const <String, TtsVoicePaths>{}),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishSpeakScreen(text: _passage, source: 's'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Escuchar'));
    await tester.pumpAndSettle();

    expect(find.text('Descargar voz en inglés'), findsOneWidget);
  });

  testWidgets('without the microphone it says so', (tester) async {
    await tester.pumpWidget(_app(recorder: _FakeRecorder(allowed: false)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Grabar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('micrófono'), findsOneWidget);
  });

  testWidgets('a failed transcription is said, and nothing is kept',
      (tester) async {
    final archive = _FakeArchive();
    await tester.pumpWidget(_app(
      archive: archive,
      stt: _FakeStt(() => throw SttException('no model')),
    ));
    await tester.pumpAndSettle();

    await _recordOnce(tester);

    expect(find.textContaining('No se pudo transcribir'), findsOneWidget);
    expect(archive.saved, isEmpty);
  });

  testWidgets('listening says the sentence with an English voice',
      (tester) async {
    final synth = FakeSynth();
    await tester.pumpWidget(_app(synth: synth));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Escuchar'));
    await tester.pumpAndSettle();

    expect(synth.texts.single, 'Dogs sniff the ground every day.');
  });

  testWidgets('it moves on to the next sentence', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Siguiente oración'));
    await tester.pumpAndSettle();

    expect(find.text('They sleep a lot at night.'), findsOneWidget);
  });
}
