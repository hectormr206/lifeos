// From a recording of a known sentence to the sound tips.
//
// The phone model (ZIPA) writes what was said as IPA; the lexicon says what
// the sentence should sound like; the alignment and the feedback turn the
// difference into at most two tips. This is an EXTRA on top of the
// intelligibility check: when the model is missing or fails, there are
// simply no tips, and the rest of the screen stands.
//
// The native part, recognizePhones, lives in phone_recognition.dart.
library;

import 'dart:isolate';

import '../../../core/security/voice_note_file_store.dart';
import '../domain/pron_alignment.dart';
import '../domain/pron_feedback.dart';
import '../domain/pron_lexicon.dart';
import 'phone_recognition.dart';
import 'pron_model.dart';

/// What was said, as the phone model's IPA.
abstract interface class PhoneRecognizer {
  Future<String> phones(String recordingPath);
}

/// The phone model is not on this device yet.
class PronModelMissing implements Exception {
  const PronModelMissing();
}

/// ZIPA over a recording from the sealed voice-note store, in a worker
/// isolate: loading 71 MB and decoding must not stall the screen. The model
/// is loaded per recording and freed at once, as Whisper is, so it never
/// sits next to the language model.
class ZipaPhoneRecognizer implements PhoneRecognizer {
  ZipaPhoneRecognizer(this._models, {VoiceNoteFileStore? voiceNotes})
      : _voiceNotes = voiceNotes ?? VoiceNoteFileStore();

  final PronModelGateway _models;
  final VoiceNoteFileStore _voiceNotes;

  @override
  Future<String> phones(String recordingPath) async {
    final model = await _models.installedModel();
    if (model == null) throw const PronModelMissing();
    return _voiceNotes.withWav(
      recordingPath,
      (wav) => Isolate.run(() => recognizePhones(
        wavPath: wav,
        model: model.model,
        tokens: model.tokens,
      )),
    );
  }
}

class PronunciationCoach {
  PronunciationCoach(this._recognizer, this._lexicon);

  final PhoneRecognizer _recognizer;
  final Future<PronLexicon> Function() _lexicon;

  /// The tips for [sentence] as said in [recordingPath]; null when they
  /// cannot be given (no model, it failed, or the sentence was not really
  /// said). An empty list means nothing worth practising was heard.
  Future<List<SoundTip>?> tips(String recordingPath, String sentence) async {
    try {
      final ipa = await _recognizer.phones(recordingPath);
      final check = checkPronunciation(
        target: sentence,
        heardIpa: ipa,
        lexicon: await _lexicon(),
      );
      // Noise or silence is not the sentence: no tips, rather than a false
      // "nothing to practise".
      return heardEnough(check) ? soundTips(check) : null;
    } catch (_) {
      return null;
    }
  }
}
