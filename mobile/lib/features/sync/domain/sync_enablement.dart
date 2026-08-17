// The gate: sync is OFF until the user asks for it AND has proven they wrote
// down the recovery phrase.
//
// THE RULE THIS FILE EXISTS TO HOLD. A fresh install reaches full local
// functionality with zero ceremony. Nothing in here runs on first launch,
// nothing prompts, nothing blocks. LifeOS is autonomous per device; the phrase
// gates ENABLING SYNC and nothing else. Anyone asked to write down twelve
// words before typing their first note closes the app.
//
// The second rule: enabling requires a CONFIRMED ceremony. Accepting an
// unconfirmed one would let a user turn on sync having written down nothing,
// and discover it the day every device is gone.
import 'package:lifeos/core/sync/phrase.dart';
import 'package:lifeos/features/sync/data/sync_key_store.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';

class SyncEnablement {
  // The field is private (`_store`) while the parameter stays public (`store`)
  // so callers read `SyncEnablement(store: ...)` instead of the
  // underscore-prefixed name an initializing formal would force on them.
  // ignore: prefer_initializing_formals
  SyncEnablement({required SyncKeyStore store}) : _store = store;

  final SyncKeyStore _store;

  /// Sync is on exactly when key material exists. One source of truth, so a
  /// separate "enabled" flag can never disagree with whether we can actually
  /// decrypt anything.
  Future<bool> isEnabled() async => (await _store.readEntropy()) != null;

  /// Turn sync on from a ceremony the user completed.
  ///
  /// Throws [PhraseNotConfirmed] and writes NOTHING when the ceremony was not
  /// confirmed — the check comes before the write so a refused enable cannot
  /// leave key material behind.
  Future<void> enable(PhraseCeremony ceremony) async {
    if (!ceremony.isConfirmed) {
      throw const PhraseNotConfirmed();
    }
    await _store.writeEntropy(ceremony.entropy);
  }

  /// Turn sync on from a phrase typed on a NEW device.
  ///
  /// `decodePhrase` validates the checksum and throws before this method
  /// touches storage, so a mistyped phrase leaves the device exactly as it
  /// was — no half-written key material, no partially-enabled state.
  Future<void> restore(String mnemonic) async {
    final entropy = decodePhrase(mnemonic);
    await _store.writeEntropy(entropy);
  }

  /// Turn sync off and forget the key material.
  ///
  /// The local data stays: sync is additive, and disabling it must never look
  /// like a wipe. What goes is the ability to read or write envelopes.
  Future<void> disable() => _store.clear();
}
