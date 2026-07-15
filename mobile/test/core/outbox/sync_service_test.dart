// Proves SyncService (M3 slice 2): drains the outbox in strict FIFO order
// by replaying each queued entry via dio. On 2xx it removes the entry and
// continues; on a network failure it stops immediately and leaves the rest
// queued for the next attempt (never reorders/loses entries); on a definite
// 4xx it drops the poison entry (removes it + reports it via onDropped)
// instead of looping on it forever. No live engine — a hand-written
// HttpClientAdapter fake per scenario, same pattern as
// reminders_repository_test.dart.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/outbox/sync_service.dart';

/// Replays requests by path: 2xx for [okPaths], a definite 4xx for
/// [poisonPaths], otherwise throws a network-class [DioException]
/// (simulating the engine still being unreachable).
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter({
    this.okPaths = const {},
    this.poisonPaths = const {},
    this.serverErrorPaths = const {},
  });

  final Set<String> okPaths;
  final Set<String> poisonPaths;

  /// Paths that answer with a transient 5xx (engine up but failing).
  final Set<String> serverErrorPaths;
  final List<String> requestedPaths = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedPaths.add(options.path);
    if (okPaths.contains(options.path)) {
      return ResponseBody.fromString('{}', 200);
    }
    if (poisonPaths.contains(options.path)) {
      return ResponseBody.fromString('{"detail":"rejected"}', 404);
    }
    if (serverErrorPaths.contains(options.path)) {
      return ResponseBody.fromString('{"detail":"boom"}', 503);
    }
    throw DioException.connectionError(requestOptions: options, reason: 'no route to host');
  }
}

Dio _dioWith(_ScriptedAdapter adapter) => Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;

void main() {
  group('SyncService.drain', () {
    test('replays queued entries in FIFO order and removes each on success', () async {
      final outbox = InMemoryOutbox();
      await outbox.enqueue(httpMethod: 'POST', path: '/first', jsonBody: {'text': 'a'});
      await outbox.enqueue(httpMethod: 'DELETE', path: '/second');
      await outbox.enqueue(httpMethod: 'POST', path: '/third', jsonBody: {'text': 'b'});
      final adapter = _ScriptedAdapter(okPaths: {'/first', '/second', '/third'});
      final service = SyncService(_dioWith(adapter), outbox);

      await service.drain();

      expect(adapter.requestedPaths, ['/first', '/second', '/third']);
      expect(await outbox.list(), isEmpty);
    });

    test('stops on a network failure and leaves the remaining entries queued', () async {
      final outbox = InMemoryOutbox();
      await outbox.enqueue(httpMethod: 'POST', path: '/first');
      await outbox.enqueue(httpMethod: 'POST', path: '/second');
      await outbox.enqueue(httpMethod: 'POST', path: '/third');
      // /first succeeds, /second is still unreachable -> stop there.
      final adapter = _ScriptedAdapter(okPaths: {'/first'});
      final service = SyncService(_dioWith(adapter), outbox);

      await service.drain();

      expect(adapter.requestedPaths, ['/first', '/second']);
      final remaining = await outbox.list();
      expect(remaining.map((e) => e.path), ['/second', '/third']);
    });

    test('drops a poison 4xx entry (removes it, reports onDropped) instead of retrying it forever', () async {
      final outbox = InMemoryOutbox();
      await outbox.enqueue(httpMethod: 'DELETE', path: '/poison');
      await outbox.enqueue(httpMethod: 'POST', path: '/ok');
      final adapter = _ScriptedAdapter(okPaths: {'/ok'}, poisonPaths: {'/poison'});
      final dropped = <OutboxEntry>[];
      final service = SyncService(_dioWith(adapter), outbox, onDropped: dropped.add);

      await service.drain();

      expect(dropped, hasLength(1));
      expect(dropped.first.path, '/poison');
      expect(adapter.requestedPaths, ['/poison', '/ok']);
      expect(await outbox.list(), isEmpty);
    });

    test('treats a 5xx as transient: keeps the entry queued and stops draining (never drops data)', () async {
      final outbox = InMemoryOutbox();
      await outbox.enqueue(httpMethod: 'POST', path: '/flaky');
      await outbox.enqueue(httpMethod: 'POST', path: '/after');
      // /flaky answers 503 (engine up but failing). It must NOT be dropped,
      // and draining must stop so /after is not replayed out of order.
      final adapter = _ScriptedAdapter(serverErrorPaths: {'/flaky'}, okPaths: {'/after'});
      final dropped = <OutboxEntry>[];
      final service = SyncService(_dioWith(adapter), outbox, onDropped: dropped.add);

      await service.drain();

      expect(dropped, isEmpty, reason: 'a 5xx must never be dropped');
      expect(adapter.requestedPaths, ['/flaky'], reason: 'draining stops at the 5xx');
      final remaining = await outbox.list();
      expect(remaining.map((e) => e.path), ['/flaky', '/after'], reason: 'both stay queued in order');
    });

    test('a second drain() call after a poison entry does not replay it again', () async {
      final outbox = InMemoryOutbox();
      await outbox.enqueue(httpMethod: 'DELETE', path: '/poison');
      final adapter = _ScriptedAdapter(poisonPaths: {'/poison'});
      final service = SyncService(_dioWith(adapter), outbox);

      await service.drain();
      await service.drain();

      expect(adapter.requestedPaths, ['/poison']);
    });

    test('an empty outbox drains without making any request', () async {
      final outbox = InMemoryOutbox();
      final adapter = _ScriptedAdapter();
      final service = SyncService(_dioWith(adapter), outbox);

      await service.drain();

      expect(adapter.requestedPaths, isEmpty);
    });

    test('reports the pending count after each successful/dropped entry via PendingSyncReporter', () async {
      final outbox = InMemoryOutbox();
      await outbox.enqueue(httpMethod: 'POST', path: '/first');
      await outbox.enqueue(httpMethod: 'POST', path: '/second');
      final adapter = _ScriptedAdapter(okPaths: {'/first', '/second'});
      final reported = <int>[];
      final service = SyncService(_dioWith(adapter), outbox, pendingSync: _RecordingPendingSyncReporter(reported));

      await service.drain();

      expect(reported.last, 0);
    });
  });
}

class _RecordingPendingSyncReporter implements PendingSyncReporter {
  _RecordingPendingSyncReporter(this.reported);

  final List<int> reported;

  @override
  void reportPendingCount(int count) => reported.add(count);
}
