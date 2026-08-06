import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the passphrase that seals AUTOMATIC backups.
///
/// OWNER DECISION (do not re-litigate without re-reading this): the MANUAL
/// backup flow (`PassphraseDialog`, `backup_settings_screen.dart`) never
/// stores this phrase — "solo vos conocés" is a deliberate guarantee there.
/// Automatic mode is a DIFFERENT threat model, and storing it here is
/// correct, not a regression of that guarantee:
///   - Anyone who already has this DEVICE already has the plaintext data
///     being backed up (the graph DB itself, unlocked by the device's own
///     Keystore key). Caching the archive passphrase here gives a
///     device-holding attacker NOTHING they did not already have.
///   - What the passphrase actually protects is the SEALED ARCHIVE sitting
///     on the VPS, from someone who has the VPS but not the device — and
///     keeping a copy on-device does not weaken that boundary at all.
///
/// MECHANISM: reuses the exact machinery `SecureFileKeyStore`
/// (`core/security/encrypted_file_cipher.dart`) already trusts for the graph
/// DB's own key material — `flutter_secure_storage`, backed by the Android
/// Keystore / iOS Keychain / Linux Secret Service (libsecret). One storage
/// mechanism for every on-device secret in this app, not two.
class AutomaticBackupPassphraseStore {
  AutomaticBackupPassphraseStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _keyName = 'lifeos.automatic_backup.passphrase';

  /// Deliberately NOT wrapped in try/catch, unlike almost everything else in
  /// this app's best-effort schedulers. On Linux without a running
  /// gnome-keyring/kwallet, the platform backend THROWS a
  /// `PlatformException` here (see `tools/install-linux.sh`'s warning about
  /// exactly this) — and that must propagate, because a caller that
  /// swallowed it would leave "Respaldar automáticamente" looking ON while
  /// nothing is actually being stored to back up with. The caller
  /// (`backup_settings_screen.dart`) is responsible for turning this into a
  /// loud, specific failure and for NOT flipping the switch.
  Future<void> save(String passphrase) =>
      _storage.write(key: _keyName, value: passphrase);

  /// Null when automatic backups were never turned on, or were turned off
  /// (which deletes the key) — a normal, expected state, not an error.
  Future<String?> load() => _storage.read(key: _keyName);

  /// The opt-out must actually remove the secret, not just stop the
  /// scheduler — a switch labelled "off" that leaves the passphrase sitting
  /// in the keystore would be lying to the user about what "off" means.
  Future<void> delete() => _storage.delete(key: _keyName);
}
