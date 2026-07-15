import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../../../core/outbox/outbox.dart';
import '../data/settings_repository.dart';
import '../domain/config_field_descriptor.dart';

/// Real [SettingsRepository] used app-wide; overridden with a fake in
/// tests. Wired with the offline read cache + connectivity reporter (M3
/// slice 1) and the offline write outbox + pending-sync reporter (M3
/// slice 2), same as every other mutating repository provider.
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) => HttpSettingsRepository(
      ref.watch(dioProvider),
      cache: ref.watch(responseCacheProvider),
      connectivity: ref.watch(connectivityStatusProvider.notifier),
      outbox: ref.watch(outboxProvider),
      pendingSync: ref.watch(pendingSyncCountProvider.notifier),
    ));

/// The settings screen's UI state: the loaded field descriptors
/// (loading/data/error) plus the save sub-state (saving/saveError,
/// optionally scoped to one [saveErrorField] so the form can highlight the
/// exact rejected field) — mirrors `RemindersUiState`'s
/// list-plus-sub-action-state shape.
class SettingsUiState {
  const SettingsUiState({
    this.fields = const [],
    this.loading = true,
    this.error,
    this.saving = false,
    this.saveError,
    this.saveErrorField,
  });

  final List<ConfigFieldDescriptor> fields;
  final bool loading;
  final String? error;
  final bool saving;
  final String? saveError;
  final String? saveErrorField;

  SettingsUiState copyWith({
    List<ConfigFieldDescriptor>? fields,
    bool? loading,
    String? error,
    bool? saving,
    String? saveError,
    String? saveErrorField,
  }) =>
      SettingsUiState(
        fields: fields ?? this.fields,
        loading: loading ?? this.loading,
        error: error,
        saving: saving ?? this.saving,
        saveError: saveError,
        saveErrorField: saveErrorField,
      );
}

/// Manages the config fields list + save lifecycle. Mirrors
/// `RemindersNotifier`'s load/refresh/mutate pattern.
class SettingsNotifier extends Notifier<SettingsUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial load deterministically.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  SettingsUiState build() {
    _bootstrapFuture = _load();
    return const SettingsUiState();
  }

  Future<void> _load() async {
    try {
      final fields = await ref.read(settingsRepositoryProvider).fetchConfig();
      state = state.copyWith(fields: fields, loading: false);
    } on SettingsException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    } catch (error) {
      state = state.copyWith(loading: false, error: 'No se pudo cargar la configuración: $error');
    }
  }

  Future<void> refresh() => _load();

  /// Client-side validation for a single field's candidate value, delegated
  /// to the loaded [ConfigFieldDescriptor.validate] — `null` when [name]
  /// isn't a currently-known field (never blocks on an unknown key; the
  /// engine is the final authority there).
  String? validate(String name, Object? candidate) {
    for (final field in state.fields) {
      if (field.name == name) return field.validate(candidate);
    }
    return null;
  }

  /// Saves [changes] — the map of field name -> new value for ONLY the
  /// fields the user actually edited (the diff against the currently-loaded
  /// descriptors is computed by `SettingsScreen`, not here, so this stays a
  /// thin pass-through the same way `RemindersNotifier.markDone` is). An
  /// empty map is a no-op success (nothing to save). Returns `true` on
  /// success, `false` on a validation rejection (see [SettingsUiState.saveError]
  /// / [SettingsUiState.saveErrorField]).
  Future<bool> save(Map<String, Object?> changes) async {
    if (changes.isEmpty) return true;
    state = state.copyWith(saving: true, saveError: null, saveErrorField: null);
    try {
      final fields = await ref.read(settingsRepositoryProvider).updateConfig(changes);
      state = state.copyWith(saving: false, fields: fields);
      return true;
    } on SettingsException catch (error) {
      state = state.copyWith(saving: false, saveError: error.message, saveErrorField: error.field);
      return false;
    } catch (error) {
      state = state.copyWith(saving: false, saveError: 'No se pudo guardar: $error');
      return false;
    }
  }
}

final settingsNotifierProvider = NotifierProvider<SettingsNotifier, SettingsUiState>(SettingsNotifier.new);
