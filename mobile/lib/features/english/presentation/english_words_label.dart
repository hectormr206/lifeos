library;

import '../../../l10n/app_localizations.dart';
import '../domain/vocab_placement_scoring.dart';

/// "About 2900 words", or "Fewer than 1000 words" below one full band.
///
/// The test measures in bands of a thousand, so below one band a count is
/// noise, and "about 0 words" was the first thing a beginner read on the real
/// Pixel. One function, so every screen says it the same way.
String englishWordsLabel(AppLocalizations l10n, int words) => words < kBandSize
    ? l10n.englishPlacementFewWords(kBandSize)
    : l10n.englishPlacementWords(words);
