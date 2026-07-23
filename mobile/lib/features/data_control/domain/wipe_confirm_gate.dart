/// The typed-confirmation gate protecting the full wipe (data-control kit).
///
/// Pure logic (no widgets) so the layered protection is unit-testable:
///  1. an explanation screen (what is deleted vs kept) — UI only;
///  2. the user must TYPE the confirmation word ([requiredWordFor]);
///  3. the final button stays disabled through a countdown
///     ([countdownSeconds]) that only starts once the word matches.
library;

class WipeConfirmGate {
  const WipeConfirmGate._();

  /// Seconds the final confirm button stays disabled AFTER the typed word
  /// matches, so the destructive tap can never be an accident.
  static const int countdownSeconds = 5;

  /// The word the user must type: BORRAR in Spanish, DELETE in English.
  static String requiredWordFor(String languageCode) =>
      languageCode == 'en' ? 'DELETE' : 'BORRAR';

  /// Whether [input] unlocks the countdown. Whitespace is trimmed and the
  /// match is case-insensitive — the ceremony is typing the word, not
  /// fighting the phone keyboard's auto-capitalization.
  static bool matches(String input, String languageCode) =>
      input.trim().toUpperCase() == requiredWordFor(languageCode);
}
