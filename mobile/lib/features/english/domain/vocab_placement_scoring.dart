// Scoring a yes/no vocabulary placement.
//
// The learner sees real English words, grouped by frequency in bands of a
// thousand, mixed with invented words that look real. Answering "I know it" to
// an invented word is a guess we can SEE, so every band is corrected by that
// guessing rate before a level is claimed. Without it, someone who taps "yes"
// to everything would be told they are C2, which is the most flattering and
// the most useless answer this test could give.
//
// The level comes from Milton & Alexiou (2009, "Vocabulary size and the Common
// European Framework of Reference for Languages"), which relates X-Lex scores
// (known words among the 5000 most frequent) to CEFR levels. Their own words:
// the sizes are "indicative, not absolute requirements". So is this result: it
// measures written, receptive vocabulary, and nothing about speaking.
library;

/// Size of one frequency band: band 0 is the 1000 most frequent words.
const int kBandSize = 1000;

/// X-Lex, and the table the CEFR level comes from, only covers the 5000 most
/// frequent words. Bands beyond this still count toward [estimatedWords].
const int kXlexBands = 5;

/// Above this share of invented words "known", the answers say more about
/// guessing than about vocabulary. A product threshold, not a published one.
const double kMaxReliableFalseAlarmRate = 1 / 3;

/// Guessing cannot be measured from a handful of invented words.
const int kMinPseudowordsForReliability = 6;

enum CefrLevel { a1, a2, b1, b2, c1, c2 }

/// How the learner answered the real words of one band.
class BandTally {
  const BandTally({required this.shown, required this.yes});

  final int shown;
  final int yes;

  double get hitRate => shown == 0 ? 0 : yes / shown;
}

/// Every answer of one placement, in band order.
class PlacementTallies {
  const PlacementTallies({
    required this.bands,
    required this.pseudoShown,
    required this.pseudoYes,
  });

  /// Index 0 is the most frequent band. Bands the test never reached are
  /// simply absent, and count as unknown.
  final List<BandTally> bands;
  final int pseudoShown;
  final int pseudoYes;

  double get falseAlarmRate => pseudoShown == 0 ? 0 : pseudoYes / pseudoShown;
}

class VocabPlacementResult {
  const VocabPlacementResult({
    required this.knownByBand,
    required this.falseAlarmRate,
    required this.estimatedWords,
    required this.xlexScore,
    required this.cefr,
    required this.reliable,
  });

  /// Share of each band the learner knows, after the guessing correction.
  final List<double> knownByBand;
  final double falseAlarmRate;

  /// Across every band tested, including those beyond the first 5000.
  final int estimatedWords;

  /// Known words among the 5000 most frequent: the scale the CEFR table uses.
  final int xlexScore;
  final CefrLevel cefr;

  /// False when the answers cannot support a level. The screen should offer a
  /// retake instead of presenting [cefr] as a finding.
  final bool reliable;
}

/// The standard correction for guessing: the share of a band the learner
/// knows, given how often they "knew" words that do not exist.
double correctedKnownRate(double hitRate, double falseAlarmRate) {
  if (falseAlarmRate >= 1) return 0;
  final known = (hitRate - falseAlarmRate) / (1 - falseAlarmRate);
  return known.clamp(0, 1).toDouble();
}

/// Milton & Alexiou (2009), English column. The published ranges leave
/// 2500-2750 unassigned; a level is only claimed once its lower bound is
/// reached, so that gap stays A2.
CefrLevel cefrForXlexScore(int score) {
  if (score >= 4500) return CefrLevel.c2;
  if (score >= 3750) return CefrLevel.c1;
  if (score >= 3250) return CefrLevel.b2;
  if (score >= 2750) return CefrLevel.b1;
  if (score >= 1500) return CefrLevel.a2;
  return CefrLevel.a1;
}

VocabPlacementResult scoreVocabPlacement(PlacementTallies tallies) {
  final falseAlarms = tallies.falseAlarmRate;
  final known = [
    for (final band in tallies.bands)
      correctedKnownRate(band.hitRate, falseAlarms),
  ];

  double wordsIn(Iterable<double> bands) =>
      bands.fold(0, (sum, rate) => sum + rate * kBandSize);

  final xlexScore = wordsIn(known.take(kXlexBands)).round();
  return VocabPlacementResult(
    knownByBand: known,
    falseAlarmRate: falseAlarms,
    estimatedWords: wordsIn(known).round(),
    xlexScore: xlexScore,
    cefr: cefrForXlexScore(xlexScore),
    reliable: tallies.pseudoShown >= kMinPseudowordsForReliability &&
        falseAlarms <= kMaxReliableFalseAlarmRate,
  );
}
