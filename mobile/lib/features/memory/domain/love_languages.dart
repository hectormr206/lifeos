/// The couple observation.
///
/// ATTRIBUTION AND SCOPE. The underlying idea — that people express affection
/// in different ways, and may not receive it in the way their partner offers
/// it — is a widely discussed one, popularised by Gary Chapman. Ideas and
/// systems are not what copyright protects; expression is. So nothing of his
/// expression is reproduced here: no text, no examples, and above all NO
/// QUESTIONNAIRE. His assessment is the part someone would actually be copying,
/// and it is deliberately absent — see the note below on why the quiz was the
/// wrong build anyway.
///
/// The category names below are ordinary descriptive Spanish phrases used to
/// label what the vocabulary matches. The vocabulary itself is original, written
/// from how people in Mexico actually speak.
///
/// This project is not affiliated with, endorsed by, or connected to Gary
/// Chapman or his publishers, and must never present itself as such. The
/// trademarked title is not used as a product, feature or marketing name
/// anywhere the user can see — a guard test enforces that, because a future
/// contributor reaching for the "obvious" label is exactly how that line gets
/// crossed by accident.
///
/// WHAT THIS DELIBERATELY IS NOT. The obvious build is: quiz the user for the
/// five languages, store the partner's, then remind him to "perform an act of
/// service". Do not. That turns affection into an overdue task, and a task is
/// the one thing love does not survive being. It gets muted within a week and
/// takes the rest of the feature with it.
///
/// WHAT THE BOOK ACTUALLY SAYS. Each person gives love in their own language,
/// and their partner may not receive it in that one. Two people genuinely
/// trying, neither feeling loved. That is the misunderstanding worth naming.
///
/// WHAT SOFTWARE CAN ADD. Exactly one thing: notice the mismatch.
///
///     "Lo que más registras dar son actos de servicio.
///      Lo que ella menciona valorar es tiempo de calidad."
///
/// An observation, not an instruction. It is the thing a person cannot see
/// from inside, because from inside it is obvious you are showing love — you
/// are, just in your own language.
///
/// PRECISION-FIRST, and quiet by default: an unreadable act is left
/// unclassified rather than guessed, and the observation stays silent on thin
/// evidence, on one-sided evidence, and when both already speak the same
/// language. Silence is the correct output far more often than not.
library;

enum LoveLanguage {
  wordsOfAffirmation,
  actsOfService,
  gifts,
  qualityTime,
  physicalTouch,
}

/// Who the act came from: something the user recorded GIVING, or something
/// they recorded their partner VALUING.
enum Side { user, partner }

class Act {
  const Act({required this.text, required this.by});
  final String text;
  final Side by;
}

/// Neutral-Spanish names, used in the observation text.
const Map<LoveLanguage, String> loveLanguageNames = {
  LoveLanguage.wordsOfAffirmation: 'palabras de afirmación',
  LoveLanguage.actsOfService: 'actos de servicio',
  LoveLanguage.gifts: 'regalos',
  LoveLanguage.qualityTime: 'tiempo de calidad',
  LoveLanguage.physicalTouch: 'contacto físico',
};

/// Deterministic vocabulary, in the order it is tested. No model: a small model
/// asked to classify intimate notes is both unreliable and the last place to
/// spend a user's privacy.
const Map<LoveLanguage, List<String>> _vocabulary = {
  LoveLanguage.qualityTime: [
    'salimos', 'salgamos', 'platicamos', 'platicáramos', 'platiquemos',
    'caminata', 'juntos', 'solos', 'sin teléfonos', 'sin telefonos',
    'tiempo juntos', 'cenar solos', 'paseamos',
  ],
  LoveLanguage.physicalTouch: [
    'abraz', 'abrazados', 'beso', 'bes', 'de la mano', 'caricia', 'acurruc',
    'masaje',
  ],
  LoveLanguage.gifts: [
    'flores', 'regal', 'le compré', 'le compre', 'detalle', 'sorpresa',
    'chocolates',
  ],
  LoveLanguage.wordsOfAffirmation: [
    'le dije', 'orgullos', 'la admiro', 'le agradecí', 'le agradeci',
    'cumplido', 'lo que pienso de ella', 'le escribí', 'le escribi',
  ],
  LoveLanguage.actsOfService: [
    'lavé', 'lave ', 'arreglé', 'arregle ', 'desayuno', 'cociné', 'cocine ',
    'el tanque', 'la llevé', 'la lleve', 'limpié', 'limpie ', 'ayudé',
    'ayude ', 'arreglara', 'lavara', 'hiciera el desayuno', 'arreglo cosas',
  ],
};

/// The language an act expresses, or null when it cannot be read.
///
/// Null is a real answer: a wrong classification quietly skews the whole
/// observation, and the observation is about someone's marriage.
LoveLanguage? classifyAct(String text) {
  final t = text.toLowerCase();
  if (t.trim().isEmpty) return null;
  for (final entry in _vocabulary.entries) {
    for (final term in entry.value) {
      if (t.contains(term)) return entry.key;
    }
  }
  return null;
}

/// A mismatch worth naming.
class LoveLanguageObservation {
  const LoveLanguageObservation({
    required this.userGivesMost,
    required this.partnerValuesMost,
  });

  final LoveLanguage userGivesMost;
  final LoveLanguage partnerValuesMost;

  /// States what is. No imperative, no task, no score — the user draws their
  /// own conclusion, which is the only kind that changes anything here.
  String describe() =>
      'Lo que más registras dar son ${loveLanguageNames[userGivesMost]}. '
      'Lo que ella menciona valorar es ${loveLanguageNames[partnerValuesMost]}.';
}

/// Minimum readable acts per side before a pattern is claimed. Two are an
/// anecdote, and announcing a pattern from an anecdote is how software earns
/// distrust on something this personal.
const int kMinimumActsPerSide = 3;

/// The mismatch, or null — which is the common and correct answer.
LoveLanguageObservation? observeLoveLanguages(Iterable<Act> acts) {
  final given = <LoveLanguage, int>{};
  final valued = <LoveLanguage, int>{};

  for (final act in acts) {
    final language = classifyAct(act.text);
    if (language == null) continue;
    final bucket = act.by == Side.user ? given : valued;
    bucket[language] = (bucket[language] ?? 0) + 1;
  }

  final givesMost = _clearLeader(given);
  final valuesMost = _clearLeader(valued);
  if (givesMost == null || valuesMost == null) return null;

  // Both already speaking the same language: there is no misunderstanding to
  // point at, and saying something anyway is the noise that gets a feature
  // like this silenced.
  if (givesMost == valuesMost) return null;

  return LoveLanguageObservation(
    userGivesMost: givesMost,
    partnerValuesMost: valuesMost,
  );
}

/// The single most frequent language, if there are enough acts AND it is not
/// tied. A tie is not a finding.
LoveLanguage? _clearLeader(Map<LoveLanguage, int> counts) {
  if (counts.isEmpty) return null;
  final total = counts.values.reduce((a, b) => a + b);
  if (total < kMinimumActsPerSide) return null;

  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (sorted.length > 1 && sorted[0].value == sorted[1].value) return null;
  return sorted.first.key;
}
