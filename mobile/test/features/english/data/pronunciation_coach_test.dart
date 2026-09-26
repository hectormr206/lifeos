// From a recording of a known sentence to the sound tips, and the model
// download state that gates it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/pron_model.dart';
import 'package:lifeos/features/english/data/pronunciation_coach.dart';
import 'package:lifeos/features/english/domain/pron_feedback.dart';
import 'package:lifeos/features/english/domain/pron_lexicon.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';

class _Recognizer implements PhoneRecognizer {
  _Recognizer(this.ipa, {this.missing = false, this.broken = false});
  final String ipa;
  final bool missing;
  final bool broken;
  String? path;

  @override
  Future<String> phones(String recordingPath) async {
    path = recordingPath;
    if (missing) throw const PronModelMissing();
    if (broken) throw Exception('native failure');
    return ipa;
  }
}

class _Gateway implements PronModelGateway {
  _Gateway({this.installed = false, this.fail = false});
  bool installed;
  final bool fail;

  @override
  Future<PronModelPaths?> installedModel() async =>
      installed ? const PronModelPaths(model: 'm', tokens: 't') : null;

  @override
  Future<PronModelPaths> download({void Function(double progress)? onProgress}) async {
    onProgress?.call(0.5);
    if (fail) throw PronModelDownloadException('no');
    installed = true;
    return const PronModelPaths(model: 'm', tokens: 't');
  }
}

final _lexicon = PronLexicon.parse('the DH AH0\nship SH IH1 P\nvery V EH1 R IY0');

void main() {
  group('PronunciationCoach', () {
    test('a recording of a sentence gives its sound tips', () async {
      final recognizer = _Recognizer('ðəbɛɹiʃip');
      final coach = PronunciationCoach(recognizer, () async => _lexicon);

      final tips = await coach.tips('/voice/note.wav.enc', 'The very ship');

      expect(recognizer.path, '/voice/note.wav.enc');
      expect(tips!.map((t) => t.pattern), [SoundPattern.shortI, SoundPattern.vAsB]);
    });

    test('noise instead of the sentence gives no tips, not "nothing to fix"',
        () async {
      final coach = PronunciationCoach(_Recognizer('b'), () async => _lexicon);

      expect(await coach.tips('/n.wav', 'The very ship'), isNull);
    });

    test('without the model there are no tips to give, and no error', () async {
      final coach = PronunciationCoach(
          _Recognizer('', missing: true), () async => _lexicon);

      expect(await coach.tips('/n.wav', 'The ship'), isNull);
    });

    test('a native failure also gives none: the rest of the screen stands',
        () async {
      final coach = PronunciationCoach(
          _Recognizer('', broken: true), () async => _lexicon);

      expect(await coach.tips('/n.wav', 'The ship'), isNull);
    });
  });

  group('pronModelStatusProvider', () {
    ProviderContainer container(_Gateway gateway) {
      final c = ProviderContainer(overrides: [
        pronModelGatewayProvider.overrideWithValue(gateway),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('ready when the files are on disk, absent otherwise', () async {
      final ready = container(_Gateway(installed: true));
      await ready.read(pronModelStatusProvider.notifier).ready;
      expect(ready.read(pronModelStatusProvider).state, PronModelState.ready);

      final absent = container(_Gateway());
      await absent.read(pronModelStatusProvider.notifier).ready;
      expect(absent.read(pronModelStatusProvider).state, PronModelState.absent);
    });

    test('download goes through progress to ready', () async {
      final c = container(_Gateway());
      final notifier = c.read(pronModelStatusProvider.notifier);
      await notifier.ready;
      final seen = <PronModelState>[];
      c.listen(pronModelStatusProvider, (_, next) => seen.add(next.state));

      await notifier.download();

      expect(seen, [PronModelState.downloading, PronModelState.downloading,
          PronModelState.ready]);
    });

    test('a failed download can be retried', () async {
      final c = container(_Gateway(fail: true));
      final notifier = c.read(pronModelStatusProvider.notifier);
      await notifier.ready;

      await notifier.download();

      expect(c.read(pronModelStatusProvider).state, PronModelState.failed);
    });
  });
}
