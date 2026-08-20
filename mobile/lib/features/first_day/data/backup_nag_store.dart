import 'package:shared_preferences/shared_preferences.dart';

/// Lo que hay que recordar entre una pregunta y la siguiente: cuándo dijo
/// "luego" por última vez, cuántas veces lo ha dicho, y si ya existe una copia.
///
/// Vive en preferencias y no en el grafo a propósito: es un hecho de ESTE
/// aparato. Que la laptop tenga una copia no significa que el teléfono la
/// tenga, y sincronizar este dato haría que los dos dejaran de preguntar
/// cuando sólo uno está a salvo.
class BackupNagStore {
  BackupNagStore({SharedPreferences? prefs}) : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String postponedKey = 'backup_nag_postponed_at';
  static const String timesKey = 'backup_nag_times';
  static const String backedUpKey = 'backup_nag_has_backup';

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<DateTime?> postponedAt() async {
    final raw = (await _instance).getString(postponedKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<int> askedTimes() async => (await _instance).getInt(timesKey) ?? 0;

  Future<bool> hasBackup() async =>
      (await _instance).getBool(backedUpKey) ?? false;

  /// "Luego". Suma una vez, para que la siguiente espera sea más larga.
  Future<void> postpone(DateTime now) async {
    final prefs = await _instance;
    await prefs.setString(postponedKey, now.toIso8601String());
    await prefs.setInt(timesKey, (prefs.getInt(timesKey) ?? 0) + 1);
  }

  /// Hay copia. Se llama cuando el respaldo automático termina bien o cuando
  /// la persona dice que ya guardó la suya.
  Future<void> markBackedUp() async =>
      (await _instance).setBool(backedUpKey, true);
}
