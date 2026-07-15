// Proves SettingsNotifier's lifecycle: loading -> data on init, error
// surfacing, refresh, and save() forwarding an already-diffed changes map
// to the repository (the diff itself is computed by SettingsScreen against
// the currently-loaded descriptors — see settings_screen_test.dart). No
// live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/settings/data/settings_repository.dart';
import 'package:lifeos/features/settings/domain/config_field_descriptor.dart';
import 'package:lifeos/features/settings/presentation/settings_notifier.dart';

class _FakeSettingsRepository implements SettingsRepository {
  _FakeSettingsRepository({this.fields = const [], this.fetchError, this.updateError, this.updatedFields});

  final List<ConfigFieldDescriptor> fields;
  final SettingsException? fetchError;
  final SettingsException? updateError;
  final List<ConfigFieldDescriptor>? updatedFields;
  int fetchCalls = 0;
  Map<String, Object?>? lastChanges;

  @override
  Future<List<ConfigFieldDescriptor>> fetchConfig() async {
    fetchCalls++;
    if (fetchError != null) throw fetchError!;
    return fields;
  }

  @override
  Future<List<ConfigFieldDescriptor>> updateConfig(Map<String, Object?> changes) async {
    lastChanges = changes;
    if (updateError != null) throw updateError!;
    return updatedFields ?? fields;
  }
}

void main() {
  group('SettingsNotifier', () {
    const ttsField = ConfigFieldDescriptor(name: 'tts_enabled', type: ConfigValueType.boolean, value: true);

    test('loads config fields on init', () async {
      final repo = _FakeSettingsRepository(fields: const [ttsField]);
      final container = ProviderContainer(overrides: [settingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(settingsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(settingsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.fields, [ttsField]);
      expect(state.error, isNull);
    });

    test('error path surfaces the error message and keeps fields empty', () async {
      final repo = _FakeSettingsRepository(fetchError: SettingsException('boom'));
      final container = ProviderContainer(overrides: [settingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(settingsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(settingsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.fields, isEmpty);
      expect(state.error, 'boom');
    });

    test('refresh reloads fields from the repository', () async {
      final repo = _FakeSettingsRepository();
      final container = ProviderContainer(overrides: [settingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(settingsNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.fetchCalls, 1);

      await notifier.refresh();

      expect(repo.fetchCalls, 2);
    });

    test('save forwards the changes map to the repository and updates state on success', () async {
      final updated = [const ConfigFieldDescriptor(name: 'tts_enabled', type: ConfigValueType.boolean, value: false)];
      final repo = _FakeSettingsRepository(fields: const [ttsField], updatedFields: updated);
      final container = ProviderContainer(overrides: [settingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(settingsNotifierProvider.notifier);
      await notifier.ready;

      final ok = await notifier.save({'tts_enabled': false});

      expect(ok, isTrue);
      expect(repo.lastChanges, {'tts_enabled': false});
      final state = container.read(settingsNotifierProvider);
      expect(state.fields, updated);
      expect(state.saving, isFalse);
      expect(state.saveError, isNull);
    });

    test('save surfaces a validation error (message + field) and does not throw', () async {
      final repo = _FakeSettingsRepository(
        fields: const [ttsField],
        updateError: SettingsException('must be >= 1', field: 'meeting_window_minutes'),
      );
      final container = ProviderContainer(overrides: [settingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(settingsNotifierProvider.notifier);
      await notifier.ready;

      final ok = await notifier.save({'meeting_window_minutes': 0});

      expect(ok, isFalse);
      final state = container.read(settingsNotifierProvider);
      expect(state.saving, isFalse);
      expect(state.saveError, 'must be >= 1');
      expect(state.saveErrorField, 'meeting_window_minutes');
    });

    test('save with an empty changes map is a no-op and does not call the repository', () async {
      final repo = _FakeSettingsRepository(fields: const [ttsField]);
      final container = ProviderContainer(overrides: [settingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(settingsNotifierProvider.notifier);
      await notifier.ready;

      final ok = await notifier.save(const {});

      expect(ok, isTrue);
      expect(repo.lastChanges, isNull);
    });
  });
}
