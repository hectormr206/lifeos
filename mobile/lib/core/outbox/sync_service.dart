import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_providers.dart';
import '../connectivity/connectivity_status.dart';
import 'outbox.dart';

/// Drains the offline write outbox (M3 slice 2) by replaying each queued
/// [OutboxEntry] via [Dio], strictly in FIFO order:
///
/// - 2xx -> the entry is removed and draining continues with the next one.
/// - network failure (see [isNetworkFailure]) -> draining STOPS immediately;
///   this and every entry after it stay queued for the next attempt. Losing
///   FIFO order or skipping ahead would replay a later mutation before an
///   earlier one the user made first.
/// - a 5xx server error -> treated as TRANSIENT (the engine is up but failing
///   — restarting, overloaded, mid-migration). Draining STOPS and the entry
///   stays queued, exactly like a network failure. We must never silently
///   drop the user's data on a transient fault ("losing the phone must never
///   mean losing your life").
/// - a 4xx client rejection -> the entry is a poison entry: the request is
///   malformed/unacceptable and will NEVER succeed, so it is removed and
///   reported via [onDropped] instead of blocking the queue forever, then
///   draining continues with the next entry.
class SyncService {
  SyncService(
    this._dio,
    this._outbox, {
    PendingSyncReporter? pendingSync,
    void Function(OutboxEntry entry)? onDropped,
  })  : _pendingSync = pendingSync ?? const NoopPendingSyncReporter(),
        _onDropped = onDropped ?? ((_) {});

  final Dio _dio;
  final Outbox _outbox;
  final PendingSyncReporter _pendingSync;
  final void Function(OutboxEntry entry) _onDropped;

  bool _draining = false;

  /// Reentrant-safe: a drain already in flight (e.g. triggered by both the
  /// app-start call and a fast reconnect) is a no-op rather than running the
  /// queue twice concurrently.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final entries = await _outbox.list();
      for (final entry in entries) {
        try {
          await _dio.request<Object?>(
            entry.path,
            data: entry.jsonBody,
            options: Options(method: entry.httpMethod),
          );
          await _outbox.remove(entry.id);
        } on DioException catch (error) {
          if (isNetworkFailure(error)) {
            return;
          }
          final status = error.response?.statusCode ?? 0;
          if (status >= 500) {
            // Transient server error — keep queued, stop draining, retry
            // on the next trigger. Never drop the user's data on a 5xx.
            return;
          }
          // 4xx: the engine definitively rejected this request; it will never
          // succeed, so drop it rather than blocking the queue forever.
          await _outbox.remove(entry.id);
          _onDropped(entry);
        }
        await _reportPendingCount();
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _reportPendingCount() async {
    _pendingSync.reportPendingCount((await _outbox.list()).length);
  }
}

final syncServiceProvider = Provider<SyncService>((ref) => SyncService(
      ref.watch(dioProvider),
      ref.watch(outboxProvider),
      pendingSync: ref.watch(pendingSyncCountProvider.notifier),
    ));

/// Arms the outbox drain triggers (M3 slice 2): once immediately (covers
/// "app start", including a fresh app open that already has queued entries
/// from a previous offline session) and again every time
/// [connectivityStatusProvider] transitions INTO
/// [ConnectivityState.online] (a reconnect). A plain [Provider] — there is
/// no UI-facing state here, its only job is the side effect of starting to
/// listen, so reading/watching it once (see `app.dart`) is enough to arm it
/// for the app's lifetime.
final outboxSyncTriggerProvider = Provider<void>((ref) {
  final service = ref.watch(syncServiceProvider);
  ref.listen<ConnectivityStatus>(connectivityStatusProvider, (previous, next) {
    final wasOnline = previous?.state == ConnectivityState.online;
    if (next.state == ConnectivityState.online && !wasOnline) {
      service.drain();
    }
  });
  service.drain();
});
