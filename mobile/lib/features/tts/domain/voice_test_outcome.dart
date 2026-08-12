/// What actually happened when the user tapped "Probar voz" — and what, if
/// anything, can be done about it.
///
/// WHY THIS EXISTS. [TextToSpeechGateway.speak] returns `Future<void>`: it says
/// nothing about whether a sound was ever produced, and the composite
/// Piper-preferred gateway swallows EVERY failure in a bare `catch (_)` so the
/// chat button never dies. That is right for chat and wrong for a diagnostic
/// control: "Probar voz" was a button that took ~90 seconds and then reported
/// absolutely nothing — success and total failure looked identical.
///
/// Two things are modelled here, and the second one is the part that is easy to
/// get wrong:
///
///  1. WHY it failed ([VoiceTestFailure]) — each value is a cause observed at a
///     specific step, plus an explicit [VoiceTestFailure.unknown] for the ones
///     we could not attribute.
///  2. That SUCCESS IS NOT ONE THING ([VoiceTestSpoke.engine]). Speaking with
///     the robotic system voice because the neural one was unavailable is a
///     materially different result from speaking with the neural voice, and the
///     user must be told which one he just heard: the neural download is
///     Wi-Fi-only (`kHeavyDownloadsRequireWiFi`), so it can sit pending
///     silently and forever while the test keeps "working".
library;

/// Why the voice test could not produce speech.
///
/// Each value is a cause we actually OBSERVED at a specific step. Nothing here
/// is a guess.
enum VoiceTestFailure {
  /// The selected NEURAL voice is not on disk (`PiperVoiceUnavailableException`).
  /// Nothing can be synthesized until it is downloaded.
  voiceMissing,

  /// The voice files are present but this device's engine cannot use them
  /// (`UnsupportedVoiceException`: `phoneme_type` is not espeak, or the voice is
  /// multi-speaker). PERMANENT for this voice — retrying is pointless.
  voiceIncompatible,

  /// The engine was reached and blew up while loading or generating
  /// (`PiperSynthesisException`). Trying again can genuinely work.
  synthesisFailed,

  /// Synthesis RAN and returned no audio at all. Distinct from
  /// [synthesisFailed] on purpose: nothing crashed, the result was simply
  /// silence, and reporting a crash that did not happen would be a fabrication.
  emptySynthesis,

  /// Audio was produced and the player refused it — the failure is downstream
  /// of the voice, so downloading another one would not help.
  playbackFailed,

  /// The neural path failed AND the OS fallback engine also failed or is not
  /// installed. There is no voice on this device at all: no in-app action
  /// fixes it.
  noEngine,

  /// Something failed that we could not attribute to any step above. Reported
  /// as unclassified ON PURPOSE — a wrong diagnosis is worse than an honest
  /// "no sé".
  unknown,
}

/// What the screen should OFFER for a failure. Derived from the failure by the
/// exhaustive switch below, never decided again at a call site — that is how a
/// permanent failure ends up offering a retry that can only fail identically.
enum VoiceTestRecovery {
  /// Transient: running the test again can succeed.
  retry,

  /// Nothing to retry — the neural voice has to be downloaded first.
  downloadVoice,

  /// Permanent for THIS voice: another voice is the only way forward.
  chooseAnotherVoice,

  /// Nothing the user can do from inside the app.
  none,
}

extension VoiceTestFailureRecovery on VoiceTestFailure {
  VoiceTestRecovery get recovery => switch (this) {
        VoiceTestFailure.voiceMissing => VoiceTestRecovery.downloadVoice,
        VoiceTestFailure.voiceIncompatible => VoiceTestRecovery.chooseAnotherVoice,
        VoiceTestFailure.noEngine => VoiceTestRecovery.none,
        VoiceTestFailure.synthesisFailed ||
        VoiceTestFailure.emptySynthesis ||
        VoiceTestFailure.playbackFailed ||
        VoiceTestFailure.unknown =>
          VoiceTestRecovery.retry,
      };
}

/// Which engine actually produced the sound.
enum VoiceTestEngine {
  /// The downloaded Piper neural voice — what the screen promises.
  neural,

  /// The OS text-to-speech voice: the always-works robotic fallback.
  system,
}

/// The result of a diagnostic speak: either something was spoken (and by WHICH
/// engine), or nothing was.
sealed class VoiceTestOutcome {
  const VoiceTestOutcome();
}

/// Speech was produced. [engine] is load-bearing: [VoiceTestEngine.system]
/// means the user heard the robotic voice, which must never be reported as if
/// the neural voice had worked.
final class VoiceTestSpoke extends VoiceTestOutcome {
  const VoiceTestSpoke(this.engine, {this.neuralFailure});

  final VoiceTestEngine engine;

  /// Why the NEURAL voice was not the one used, when the fallback spoke.
  /// Null for [VoiceTestEngine.neural] (nothing failed) and for a fallback we
  /// could not attribute. It exists so the message can say WHY the system voice
  /// answered instead of leaving the user to guess.
  final VoiceTestFailure? neuralFailure;

  @override
  bool operator ==(Object other) =>
      other is VoiceTestSpoke && other.engine == engine && other.neuralFailure == neuralFailure;

  @override
  int get hashCode => Object.hash(engine, neuralFailure);

  @override
  String toString() => 'VoiceTestSpoke(${engine.name}'
      '${neuralFailure == null ? '' : ', after ${neuralFailure!.name}'})';
}

/// Nothing was spoken.
final class VoiceTestFailed extends VoiceTestOutcome {
  const VoiceTestFailed(this.failure, {this.detail});

  final VoiceTestFailure failure;

  /// The underlying exception text, when the cause came from one. The screen
  /// keeps the plain-language sentence as the headline, but this is the only
  /// evidence that exists on the device where the failure actually happens.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is VoiceTestFailed && other.failure == failure && other.detail == detail;

  @override
  int get hashCode => Object.hash(failure, detail);

  @override
  String toString() => 'VoiceTestFailed(${failure.name}'
      '${detail == null ? '' : ': $detail'})';
}
