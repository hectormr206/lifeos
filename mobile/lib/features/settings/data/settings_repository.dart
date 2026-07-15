import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../../../core/outbox/outbox.dart';
import '../domain/config_field_descriptor.dart';

/// Raised when a settings/config call fails (non-2xx, network error).
/// [message] is user-facing (Spanish). [field] carries the engine's
/// `ConfigError.field` (`config_schema.py`) when the failure is a validation
/// rejection from `POST /api/v1/config`, so the UI can highlight the exact
/// offending form field.
class SettingsException implements Exception {
  SettingsException(this.message, {this.statusCode, this.field});

  final String message;
  final int? statusCode;
  final String? field;

  @override
  String toString() => message;
}

/// Talks to the engine's config endpoints (`axi/src/axi/dashboard.py`).
/// Abstract so the notifier/tests can depend on a fake without a live
/// engine.
abstract class SettingsRepository {
  /// GETs `/api/v1/config` (dashboard.py:1662 `read_config` -> flat `{name:
  /// value}` dict) and `/api/v1/config/schema` (:1667 `read_config_schema`
  /// -> `config_schema.to_json_schema()`), merged into typed descriptors by
  /// [buildConfigDescriptors].
  Future<List<ConfigFieldDescriptor>> fetchConfig();

  /// POSTs `/api/v1/config` (:1674 `write_config`) with a body containing
  /// ONLY [changes] — the engine merges it with the on-disk config
  /// server-side and validates the full merged dict. Returns the freshly
  /// merged descriptors on success (200 `{"ok": true, "config": {...}}`);
  /// throws [SettingsException] (with `field` set) on a validation rejection
  /// (400, `ConfigError`).
  Future<List<ConfigFieldDescriptor>> updateConfig(Map<String, Object?> changes);
}

class HttpSettingsRepository implements SettingsRepository {
  HttpSettingsRepository(
    this._dio, {
    ResponseCache? cache,
    ConnectivityReporter? connectivity,
    Outbox? outbox,
    PendingSyncReporter? pendingSync,
  })  : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter(),
        _outbox = outbox ?? InMemoryOutbox(),
        _pendingSync = pendingSync ?? const NoopPendingSyncReporter();

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;
  final Outbox _outbox;
  final PendingSyncReporter _pendingSync;

  /// Offline read cache keys (M3 slice 1) — one for the current values, one
  /// for the (rarely-changing) schema, so a read-cache fallback can still
  /// render a fully-typed form offline.
  static const _valuesCacheKey = 'config:current';
  static const _schemaCacheKey = 'config:schema';

  @override
  Future<List<ConfigFieldDescriptor>> fetchConfig() async {
    try {
      final responses = await Future.wait([
        _dio.get<Map<String, Object?>>('/api/v1/config'),
        _dio.get<Map<String, Object?>>('/api/v1/config/schema'),
      ]);
      final values = responses[0].data ?? const <String, Object?>{};
      final schema = responses[1].data ?? const <String, Object?>{};
      _connectivity.reportOnline();
      await _cache.put(_valuesCacheKey, values);
      await _cache.put(_schemaCacheKey, schema);
      return buildConfigDescriptors(schema: schema, values: values);
    } on DioException catch (error) {
      final cachedValues = await _cache.get(_valuesCacheKey);
      final cachedSchema = await _cache.get(_schemaCacheKey);
      if (cachedValues is Map && cachedSchema is Map) {
        final fetchedAt = await _cache.fetchedAt(_valuesCacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return buildConfigDescriptors(
          schema: Map<String, Object?>.from(cachedSchema),
          values: Map<String, Object?>.from(cachedValues),
        );
      }
      _connectivity.reportOffline();
      throw SettingsException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<List<ConfigFieldDescriptor>> updateConfig(Map<String, Object?> changes) async {
    if (changes.isEmpty) return fetchConfig();
    try {
      final response = await _dio.post<Map<String, Object?>>('/api/v1/config', data: changes);
      final body = response.data ?? const <String, Object?>{};
      _connectivity.reportOnline();
      final config = body['config'];
      if (config is Map) {
        final mergedValues = Map<String, Object?>.from(config);
        await _cache.put(_valuesCacheKey, mergedValues);
        final cachedSchema = await _cache.get(_schemaCacheKey);
        if (cachedSchema is Map) {
          return buildConfigDescriptors(schema: Map<String, Object?>.from(cachedSchema), values: mergedValues);
        }
      }
      // No cached schema yet (e.g. first-ever write before a read) — do a
      // full fetch so the descriptors still come back typed.
      return fetchConfig();
    } on DioException catch (error) {
      // M3 slice 2: a network-class failure queues this POST for later
      // replay via SyncService and returns the best-effort local view
      // (falls back to the read cache) instead of throwing, mirroring
      // `HttpRemindersRepository.cancel`'s optimistic-offline pattern. A
      // definite 4xx/5xx (the engine DID answer — e.g. a `ConfigError`
      // validation rejection) still surfaces as a real [SettingsException].
      if (isNetworkFailure(error)) {
        await _outbox.enqueue(httpMethod: 'POST', path: '/api/v1/config', jsonBody: changes, kind: 'config_update');
        await _reportPendingCount();
        // Best-effort optimistic local view from the read cache (never
        // throws — unlike the read path, an offline WRITE must never block
        // the user from seeing their queued edit reflected in the UI).
        return _cachedDescriptorsWithChanges(changes);
      }
      final detail = _errorDetail(error.response?.data);
      final reason = detail?['error']?.toString();
      final field = detail?['field']?.toString();
      throw SettingsException(reason ?? _messageFor(error), statusCode: error.response?.statusCode, field: field);
    }
  }

  Future<void> _reportPendingCount() async {
    _pendingSync.reportPendingCount((await _outbox.list()).length);
  }

  /// Builds descriptors from the last cached values with [changes] applied
  /// optimistically on top, write-through-updating the values cache so a
  /// subsequent offline read sees the queued edit too. Degrades to an empty
  /// list (never throws) when nothing has ever been cached — there is no
  /// live engine and no prior read to fall back to.
  Future<List<ConfigFieldDescriptor>> _cachedDescriptorsWithChanges(Map<String, Object?> changes) async {
    final cachedValues = await _cache.get(_valuesCacheKey);
    final cachedSchema = await _cache.get(_schemaCacheKey);
    if (cachedValues is! Map || cachedSchema is! Map) return const [];
    final merged = Map<String, Object?>.from(cachedValues)..addAll(changes);
    await _cache.put(_valuesCacheKey, merged);
    return buildConfigDescriptors(schema: Map<String, Object?>.from(cachedSchema), values: merged);
  }

  /// FastAPI's default `HTTPException(status_code, detail=X)` wire shape
  /// wraps `X` under a top-level `"detail"` key (dashboard.py has no custom
  /// exception handler for `HTTPException`, only for bare `Exception` at
  /// :715 — verified by reading the file). `write_config` (:1674) raises
  /// with `detail={"error", "field", "value"}` (a `ConfigError`), so the
  /// actual response body is `{"detail": {"error": ..., "field": ...,
  /// "value": ...}}`.
  Map<String, Object?>? _errorDetail(Object? data) {
    if (data is Map) {
      final detail = data['detail'];
      if (detail is Map) return Map<String, Object?>.from(detail);
    }
    return null;
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudo guardar la configuración (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
