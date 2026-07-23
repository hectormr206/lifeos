import 'package:shared_preferences/shared_preferences.dart';

/// The tracked identity of the installed on-device chat model.
class InstalledBrainModel {
  const InstalledBrainModel({required this.modelName, required this.versionCode});

  /// Stable internal model name (e.g. `gemma-4-E2B-it`).
  final String modelName;

  /// Monotonic version of the installed weights (manifest versionCode).
  final int versionCode;

  @override
  bool operator ==(Object other) =>
      other is InstalledBrainModel &&
      other.modelName == modelName &&
      other.versionCode == versionCode;

  @override
  int get hashCode => Object.hash(modelName, versionCode);

  @override
  String toString() => 'InstalledBrainModel($modelName v$versionCode)';
}

/// Local-only persistence for the installed brain-model version (the house
/// shared_preferences pattern, like `LocalModelPreferences`). This is what
/// lets the app compare the server manifest against what's on disk and show
/// "hay un nuevo modelo disponible" — flutter_gemma itself only knows a
/// filename, never a version.
///
/// Abstracted so notifiers depend on the interface and tests inject a fake
/// without the platform channel.
abstract class BrainModelVersionStore {
  /// The tracked installed model, or null when none was ever recorded (a fresh
  /// device, OR an install that predates the OTA flow — the adopt-in-place
  /// migration case).
  Future<InstalledBrainModel?> installed();

  /// Records the installed model identity (called after a verified install).
  Future<void> setInstalled(InstalledBrainModel model);

  /// Clears the tracked identity (called when the weights are deleted).
  Future<void> clear();
}

/// [BrainModelVersionStore] backed by `shared_preferences`.
class SharedPrefsBrainModelVersionStore implements BrainModelVersionStore {
  // Same injection seam as SharedPrefsLocalModelPreferences (house pattern).
  // ignore: prefer_initializing_formals
  SharedPrefsBrainModelVersionStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String modelNameKey = 'brain_model_name';
  static const String versionCodeKey = 'brain_model_version_code';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<InstalledBrainModel?> installed() async {
    final prefs = await _instance;
    final name = prefs.getString(modelNameKey);
    final code = prefs.getInt(versionCodeKey);
    if (name == null || code == null) return null;
    return InstalledBrainModel(modelName: name, versionCode: code);
  }

  @override
  Future<void> setInstalled(InstalledBrainModel model) async {
    final prefs = await _instance;
    await prefs.setString(modelNameKey, model.modelName);
    await prefs.setInt(versionCodeKey, model.versionCode);
  }

  @override
  Future<void> clear() async {
    final prefs = await _instance;
    await prefs.remove(modelNameKey);
    await prefs.remove(versionCodeKey);
  }
}
