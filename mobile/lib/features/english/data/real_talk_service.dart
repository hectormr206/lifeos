// The before-and-after of a real conversation (domain/real_talk.dart), wired
// to the on-device model. Neither call throws: a missing or failing model, or
// an answer out of shape, comes back as null and the screen says so. Both
// prompts were checked against the real Gemma E2B with the bench.
library;

import '../../local_model/domain/local_llm_engine.dart';
import '../domain/real_talk.dart';
import '../domain/vocab_placement_scoring.dart';

class RealTalkService {
  RealTalkService(this._engine);

  final LocalLlmEngine _engine;

  /// A little variety in the phrases is welcome; a rephrase should not wander.
  static const double _prepTemperature = 0.4;
  static const double _rephraseTemperature = 0.3;

  Future<Prep?> prepare({
    required String situation,
    required CefrLevel level,
  }) async {
    try {
      final result = await _engine.generate(
        buildPrepPrompt(situation: situation, level: level),
        temperature: _prepTemperature,
      );
      return parsePrep(result.text);
    } catch (_) {
      return null;
    }
  }

  Future<String?> rephrase({
    required String wanted,
    required String situation,
  }) async {
    try {
      final result = await _engine.generate(
        buildRephrasePrompt(wanted: wanted, situation: situation),
        temperature: _rephraseTemperature,
      );
      return parseRephrase(result.text);
    } catch (_) {
      return null;
    }
  }
}
