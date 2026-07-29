import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/backup_host_config.dart';

/// Persists where the backup host is and how to authenticate to it.
///
/// The two halves are stored differently ON PURPOSE. The address is ordinary
/// configuration and lives in shared_preferences; the access key is a secret
/// and lives in the OS keystore, the same place the graph's encryption key
/// does. Putting the key in shared_preferences would leave it in a file that
/// any backup or debug tooling could scoop up.
class BackupHostConfigStore {
  BackupHostConfigStore({
    this._prefs,
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage ?? const FlutterSecureStorage();

  SharedPreferences? _prefs;
  final FlutterSecureStorage _secure;

  static const String baseUrlKey = 'backup_host_base_url';
  static const String _secureKeyName = 'lifeos.backup_host.access_key';

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<BackupHostConfig> load() async {
    final prefs = await _instance;
    final baseUrl = prefs.getString(baseUrlKey) ?? '';
    final key = await _secure.read(key: _secureKeyName) ?? '';
    return BackupHostConfig(baseUrl: baseUrl, accessKey: key);
  }

  Future<void> save(BackupHostConfig config) async {
    final prefs = await _instance;
    await prefs.setString(baseUrlKey, config.baseUrl.trim());
    final key = config.accessKey.trim();
    if (key.isEmpty) {
      await _secure.delete(key: _secureKeyName);
    } else {
      await _secure.write(key: _secureKeyName, value: key);
    }
  }

  /// Forgets the host entirely. The archives already on the server are NOT
  /// touched — they are the user's, on the user's machine, and are still
  /// openable with the passphrase from any device.
  Future<void> clear() async {
    final prefs = await _instance;
    await prefs.remove(baseUrlKey);
    await _secure.delete(key: _secureKeyName);
  }
}
