// Running a yes/no vocabulary placement, one word at a time.
//
// Bands go from the most frequent words to the rarest. Each band shows a
// random sample of its words, with invented words mixed in so guessing can be
// measured (see vocab_placement_scoring.dart). The test is adaptive in the
// one way that matters for patience: it ends once two bands in a row are
// mostly unknown. Past that point every extra word is another "no", which
// costs the learner a minute and tells us nothing new. Someone at A1 finishes
// in about 26 words; only someone who knows every band sees them all.
library;

import 'dart:math';

import 'vocab_placement_scoring.dart';

/// Real words sampled from each band. X-Lex uses 20 per thousand without
/// being adaptive; 10 keeps the full test near 130 answers, a few minutes.
const int kPlacementWordsPerBand = 10;

/// One invented word for every this many real ones, per band.
const int kRealWordsPerPseudoword = 3;

/// A band counts as "mostly unknown" below this corrected share.
const double kStopKnownRate = 0.2;

/// Consecutive mostly-unknown bands that end the test. One is not enough: a
/// single weak band can be bad luck in the sample.
const int kWeakBandsToStop = 2;

/// Words to test, grouped by frequency, and invented words to catch guessing.
class VocabBank {
  const VocabBank({required this.bands, required this.pseudowords});

  /// Index 0 holds the most frequent words.
  final List<List<String>> bands;
  final List<String> pseudowords;
}

/// One word on screen: real ones know their band, invented ones have none.
class PlacementItem {
  const PlacementItem.word(this.text, int this.band);
  const PlacementItem.pseudoword(this.text) : band = null;

  final String text;
  final int? band;

  bool get isPseudoword => band == null;
}

class VocabPlacementSession {
  VocabPlacementSession(this._bank, {Random? random})
      : _random = random ?? Random(),
        _pseudowords = [..._bank.pseudowords] {
    _pseudowords.shuffle(_random);
    _startNextBand();
  }

  final VocabBank _bank;
  final Random _random;
  final List<String> _pseudowords;

  final List<BandTally> _bands = [];
  final List<PlacementItem> _queue = [];
  int _band = -1;
  int _shown = 0;
  int _yes = 0;
  int _pseudoShown = 0;
  int _pseudoYes = 0;
  bool _finished = false;

  /// The word to ask about, or null once the test is over.
  PlacementItem? get current => _finished ? null : _queue.first;

  bool get isFinished => _finished;

  /// Every answer so far, ready for [scoreVocabPlacement].
  PlacementTallies get tallies => PlacementTallies(
        bands: List.unmodifiable(_bands),
        pseudoShown: _pseudoShown,
        pseudoYes: _pseudoYes,
      );

  void answer({required bool knows}) {
    if (_finished) {
      throw StateError('The placement is over; there is nothing to answer.');
    }
    final item = _queue.removeAt(0);
    if (item.isPseudoword) {
      _pseudoShown++;
      if (knows) _pseudoYes++;
    } else {
      _shown++;
      if (knows) _yes++;
    }
    if (_queue.isEmpty) _closeBand();
  }

  void _closeBand() {
    _bands.add(BandTally(shown: _shown, yes: _yes));
    if (_knowledgeRanOut()) {
      _finished = true;
    } else {
      _startNextBand();
    }
  }

  bool _knowledgeRanOut() {
    if (_bands.length < kWeakBandsToStop) return false;
    final falseAlarms = tallies.falseAlarmRate;
    return _bands.skip(_bands.length - kWeakBandsToStop).every(
          (band) =>
              correctedKnownRate(band.hitRate, falseAlarms) < kStopKnownRate,
        );
  }

  /// Queues the next band that has words, or ends the test when none is left.
  void _startNextBand() {
    _shown = 0;
    _yes = 0;
    while (++_band < _bank.bands.length) {
      final words = [..._bank.bands[_band]]..shuffle(_random);
      if (words.isEmpty) continue;
      _queue.addAll(_withPseudowords(words.take(kPlacementWordsPerBand)));
      return;
    }
    _finished = true;
  }

  /// One invented word at a random spot inside each full run of
  /// [kRealWordsPerPseudoword] real words, so its position gives nothing away.
  List<PlacementItem> _withPseudowords(Iterable<String> words) {
    final items = <PlacementItem>[];
    final chunk = <PlacementItem>[];
    for (final word in words) {
      chunk.add(PlacementItem.word(word, _band));
      if (chunk.length == kRealWordsPerPseudoword) {
        if (_pseudowords.isNotEmpty) {
          chunk.insert(
            _random.nextInt(chunk.length + 1),
            PlacementItem.pseudoword(_pseudowords.removeLast()),
          );
        }
        items.addAll(chunk);
        chunk.clear();
      }
    }
    return items..addAll(chunk);
  }
}
