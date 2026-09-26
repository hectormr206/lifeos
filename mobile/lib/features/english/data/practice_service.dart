// The practice prompts (domain/practice.dart), wired to the on-device model.
//
// Neither call throws: a missing model, a failing one, or an answer out of
// shape comes back as null, and the screen says so. Both prompts were checked
// against the real Gemma E2B with `lifeos --bench --bench-prompts`.
library;

import '../../local_model/domain/local_llm_engine.dart';
import '../domain/practice.dart';
import '../domain/vocab_placement_scoring.dart';

/// Low: a review is a judgement, not a creative answer.
const double kReviewTemperature = 0.3;

final RegExp _speakerLabel = RegExp(r'^(you|partner)\s*:\s*', caseSensitive: false);

class PracticeService {
  PracticeService(this._engine);

  final LocalLlmEngine _engine;

  /// The partner's next line in the role-play, or null.
  Future<String?> reply({
    required RoleplayScenario scenario,
    required CefrLevel level,
    required List<PracticeTurn> turns,
  }) async {
    try {
      final result = await _engine.generate(
        buildRoleplayPrompt(scenario: scenario, level: level, turns: turns),
      );
      final text = result.text.trim().replaceFirst(_speakerLabel, '').trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// At most two corrections of [learnerText], or null when the model could
  /// not review it.
  Future<PracticeFeedback?> review(String learnerText) async {
    try {
      final result = await _engine.generate(
        buildFeedbackPrompt(learnerText: learnerText),
        temperature: kReviewTemperature,
      );
      return parseFeedback(result.text);
    } catch (_) {
      return null;
    }
  }
}
