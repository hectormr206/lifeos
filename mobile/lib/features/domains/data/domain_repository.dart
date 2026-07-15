import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../../../core/outbox/outbox.dart';
import '../domain/domain_descriptor.dart';
import '../domain/domain_entry.dart';

/// Raised when a domain's list GET fails (non-2xx, network error). [message]
/// is user-facing (Spanish).
class DomainException implements Exception {
  DomainException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's per-domain list endpoints. Abstract so tests/the
/// notifier can depend on a fake without a live engine.
///
/// ARCHITECTURE NOTE (parity with chat, see apply-progress M1-slice-2):
/// health/finance/exercise list endpoints are not yet in
/// `contracts/openapi/axi-v1.json`, so this repository calls the engine via
/// raw [Dio] (through the shared `dioProvider`) rather than the generated
/// `axi_api_client`. Same documented follow-up as chat: promote these to
/// native typed `/api/v1` routes so the generator can emit real models.
abstract class DomainRepository {
  /// Lists entries for [descriptor]. GET `descriptor.listPath`, unwraps the
  /// JSON body via `descriptor.listKey` (handles the "entries" vs "sessions"
  /// noun difference), and parses each row into a [DomainEntry].
  Future<List<DomainEntry>> list(DomainDescriptor descriptor);

  /// Creates one entry for [descriptor] from a structured form (spec:
  /// structured-domain-forms). POSTs [body] (built by
  /// `buildDomainEntryBody`) to `descriptor.listPath` — verified against
  /// `axi/src/axi/dashboard.py`, the engine's create endpoint for all 7
  /// domains is the SAME path as the GET list (`POST /api/v1/health/entries`,
  /// `POST /api/v1/finance/entries`, etc.), so no separate "create path" is
  /// needed on [DomainDescriptor]. On a network-class failure, enqueues the
  /// POST to the offline write outbox (M3 slice 2) and returns a best-effort
  /// local [DomainEntry] instead of throwing — mirrors
  /// `HttpSettingsRepository.updateConfig`'s offline-write pattern. A
  /// definite 4xx/5xx (the engine DID answer, e.g. a validation rejection)
  /// still throws [DomainException].
  Future<DomainEntry> createEntry(DomainDescriptor descriptor, Map<String, Object?> body);
}

class HttpDomainRepository implements DomainRepository {
  HttpDomainRepository(
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

  /// Offline read cache key (M3 slice 1) — one per domain, e.g.
  /// `"domains:health:entries"`.
  String _cacheKeyFor(DomainDescriptor descriptor) => 'domains:${descriptor.key}:entries';

  @override
  Future<List<DomainEntry>> list(DomainDescriptor descriptor) async {
    final cacheKey = _cacheKeyFor(descriptor);
    try {
      final response = await _dio.get<Map<String, Object?>>(descriptor.listPath);
      final body = response.data ?? const <String, Object?>{};
      final rows = body[descriptor.listKey];
      _connectivity.reportOnline();
      if (rows is! List) return const [];
      await _cache.put(cacheKey, rows);
      return rows.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
    } on DioException catch (error) {
      final cached = await _cache.get(cacheKey);
      if (cached is List) {
        final fetchedAt = await _cache.fetchedAt(cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return cached.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
      }
      _connectivity.reportOffline();
      throw DomainException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  /// Common fields verified across all 3 domains' dict-serializers in
  /// dashboard.py (`_health_entry_to_dict`, `_finance_entry_to_dict`,
  /// `_session_to_dict`): `id`, `ts` (ISO8601), `title`. `subject` is parsed
  /// defensively — see [DomainEntry.subject] for the documented engine-side
  /// gap. Everything else stays in [DomainEntry.raw] for domain-specific
  /// display (amount/currency, duration_minutes, kind, ...).
  DomainEntry _parseRow(Map<String, Object?> row) {
    final id = row['id']?.toString() ?? '';
    final tsRaw = row['ts'] as String?;
    final timestamp = tsRaw != null ? (DateTime.tryParse(tsRaw) ?? DateTime.now()) : DateTime.now();
    return DomainEntry(
      id: id,
      title: row['title'] as String? ?? '',
      timestamp: timestamp,
      subject: row['subject'] as String?,
      raw: row,
    );
  }

  @override
  Future<DomainEntry> createEntry(DomainDescriptor descriptor, Map<String, Object?> body) async {
    try {
      final response = await _dio.post<Map<String, Object?>>(descriptor.listPath, data: body);
      final row = response.data ?? const <String, Object?>{};
      _connectivity.reportOnline();
      return _parseRow(row);
    } on DioException catch (error) {
      if (isNetworkFailure(error)) {
        await _outbox.enqueue(
          httpMethod: 'POST',
          path: descriptor.listPath,
          jsonBody: body,
          kind: '${descriptor.key}_create',
        );
        await _reportPendingCount();
        _connectivity.reportOffline();
        return _localEntryFrom(body);
      }
      throw DomainException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  Future<void> _reportPendingCount() async {
    _pendingSync.reportPendingCount((await _outbox.list()).length);
  }

  /// Best-effort optimistic entry built from the form [body] itself, used
  /// when a create is offline-enqueued rather than confirmed by the engine.
  /// The synthetic `local-` id is never a real entry id — replaced once
  /// [SyncService] drains the outbox and a subsequent list refresh pulls the
  /// canonical row.
  DomainEntry _localEntryFrom(Map<String, Object?> body) {
    final tsRaw = body['ts'] as String?;
    final timestamp = tsRaw != null ? (DateTime.tryParse(tsRaw) ?? DateTime.now()) : DateTime.now();
    return DomainEntry(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      title: body['title'] as String? ?? '',
      timestamp: timestamp,
      raw: body,
    );
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudieron cargar los registros (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
