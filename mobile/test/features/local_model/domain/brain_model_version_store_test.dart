// Proves SharedPrefsBrainModelVersionStore (brain-model OTA version tracking)
// persists + reads back the installed modelName/versionCode, reports null when
// nothing was ever tracked (the adopt-in-place migration trigger), and clears
// on delete — using shared_preferences' in-memory mock backing.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/brain_model_version_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reports null when nothing was ever tracked', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsBrainModelVersionStore();
    expect(await store.installed(), isNull);
  });

  test('persists and reads back the installed identity', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsBrainModelVersionStore();

    await store.setInstalled(
      const InstalledBrainModel(modelName: 'gemma-4-E2B-it', versionCode: 2),
    );

    expect(
      await store.installed(),
      const InstalledBrainModel(modelName: 'gemma-4-E2B-it', versionCode: 2),
    );
  });

  test('a partial record (name without version) reads as untracked', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsBrainModelVersionStore.modelNameKey: 'gemma-4-E2B-it',
    });
    final store = SharedPrefsBrainModelVersionStore();
    expect(await store.installed(), isNull);
  });

  test('clear removes the tracked identity', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsBrainModelVersionStore.modelNameKey: 'gemma-4-E2B-it',
      SharedPrefsBrainModelVersionStore.versionCodeKey: 3,
    });
    final store = SharedPrefsBrainModelVersionStore();
    expect(await store.installed(), isNotNull);

    await store.clear();
    expect(await store.installed(), isNull);
  });
}
