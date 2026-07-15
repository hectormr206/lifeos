import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// True when [error] represents a network-class failure — a connection
/// error, timeout, or similar transport-level break where the request never
/// reached the engine — as opposed to a definite server response (any
/// status code, 2xx/4xx/5xx). Dio always attaches [DioException.response]
/// when a response body actually arrived, so "no response" is exactly the
/// signal that the mutation must be queued rather than surfaced as a real
/// failure: a 4xx/5xx means the request DID reach the engine and its
/// rejection is final, not a connectivity problem.
bool isNetworkFailure(DioException error) => error.response == null;

/// A single queued mutation (M3 slice 2: offline write outbox). Captures
/// everything [SyncService] needs to replay the exact same HTTP call later:
/// the method, path, and JSON body dio originally would have sent. [kind] is
/// an optional label (e.g. `"chat_ask"`, `"reminder_cancel"`) for
/// diagnostics/UI, not used for replay itself.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.httpMethod,
    required this.path,
    this.jsonBody,
    required this.createdAt,
    this.kind,
  });

  final String id;
  final String httpMethod;
  final String path;
  final Map<String, Object?>? jsonBody;
  final DateTime createdAt;
  final String? kind;

  Map<String, Object?> toJson() => {
        'id': id,
        'httpMethod': httpMethod,
        'path': path,
        'jsonBody': jsonBody,
        'createdAt': createdAt.toIso8601String(),
        'kind': kind,
      };

  /// Any missing/malformed field degrades to a safe default rather than
  /// throwing — a single corrupt row must never break decoding the rest of
  /// the durable outbox file (mirrors `ResponseCache`'s corruption
  /// tolerance).
  static OutboxEntry fromJson(Map<String, Object?> json) {
    final rawBody = json['jsonBody'];
    return OutboxEntry(
      id: json['id'] as String? ?? '',
      httpMethod: json['httpMethod'] as String? ?? 'POST',
      path: json['path'] as String? ?? '',
      jsonBody: rawBody is Map ? Map<String, Object?>.from(rawBody) : null,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      kind: json['kind'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OutboxEntry && other.id == id && other.httpMethod == httpMethod && other.path == path;

  @override
  int get hashCode => Object.hash(id, httpMethod, path);

  @override
  String toString() => 'OutboxEntry(id: $id, $httpMethod $path, kind: $kind)';
}

final _idRandom = Random();

/// Timestamp + random suffix — unique enough for a locally-queued mutation
/// without pulling in a uuid dependency (pure-Dart constraint, same
/// rationale as the rest of this slice).
String _newOutboxId() => '${DateTime.now().microsecondsSinceEpoch}-${_idRandom.nextInt(1 << 32)}';

/// Offline write outbox abstraction (M3 slice 2: "losing the phone must
/// never mean losing your life" — the write half of M3 slice 1's read
/// cache). A mutating repository call that fails with a network-class error
/// (see [isNetworkFailure]) enqueues an [OutboxEntry] here instead of
/// failing the user's action; [SyncService] replays queued entries in FIFO
/// order once connectivity returns.
abstract class Outbox {
  /// Queues a mutation for later replay. Returns the created [OutboxEntry]
  /// (with its assigned [OutboxEntry.id] and [OutboxEntry.createdAt]).
  Future<OutboxEntry> enqueue({
    required String httpMethod,
    required String path,
    Map<String, Object?>? jsonBody,
    String? kind,
  });

  /// All currently-queued entries, oldest first (FIFO replay order).
  Future<List<OutboxEntry>> list();

  /// Removes the entry with [id] (successfully replayed, or dropped as a
  /// poison/rejected entry). A no-op if [id] is not queued.
  Future<void> remove(String id);
}

/// Simple in-memory [Outbox]. Used by tests/fakes, and as the fallback
/// default for repositories constructed without an explicit outbox.
class InMemoryOutbox implements Outbox {
  final List<OutboxEntry> _entries = [];

  @override
  Future<OutboxEntry> enqueue({
    required String httpMethod,
    required String path,
    Map<String, Object?>? jsonBody,
    String? kind,
  }) async {
    final entry = OutboxEntry(
      id: _newOutboxId(),
      httpMethod: httpMethod,
      path: path,
      jsonBody: jsonBody,
      createdAt: DateTime.now(),
      kind: kind,
    );
    _entries.add(entry);
    return entry;
  }

  @override
  Future<List<OutboxEntry>> list() async => List.unmodifiable(_entries);

  @override
  Future<void> remove(String id) async {
    _entries.removeWhere((entry) => entry.id == id);
  }
}

/// File-backed [Outbox] used in production: one JSON array file under the
/// app support directory, so queued mutations survive an app restart
/// (durability requirement, M3 slice 2). Same injectable-directory pattern
/// as `core/cache/response_cache.dart`'s `FileResponseCache`, for the same
/// testability reason (no path_provider platform channel needed in tests).
class FileOutbox implements Outbox {
  FileOutbox({Future<Directory> Function()? directoryProvider})
      : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  static const _subdir = 'outbox';
  static const _fileName = 'outbox.json';

  @override
  Future<OutboxEntry> enqueue({
    required String httpMethod,
    required String path,
    Map<String, Object?>? jsonBody,
    String? kind,
  }) async {
    final entry = OutboxEntry(
      id: _newOutboxId(),
      httpMethod: httpMethod,
      path: path,
      jsonBody: jsonBody,
      createdAt: DateTime.now(),
      kind: kind,
    );
    final entries = await _readEntries();
    entries.add(entry);
    await _writeEntries(entries);
    return entry;
  }

  @override
  Future<List<OutboxEntry>> list() => _readEntries();

  @override
  Future<void> remove(String id) async {
    final entries = await _readEntries();
    entries.removeWhere((entry) => entry.id == id);
    await _writeEntries(entries);
  }

  /// Any failure (missing file, malformed JSON, unavailable platform
  /// channel in a test environment) degrades to an empty queue rather than
  /// crashing the app — a corrupt/unavailable outbox must never block
  /// mutations from at least attempting to run, and must never break
  /// `SyncService.drain()`.
  Future<List<OutboxEntry>> _readEntries() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map((row) => OutboxEntry.fromJson(Map<String, Object?>.from(row))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeEntries(List<OutboxEntry> entries) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(entries.map((entry) => entry.toJson()).toList()));
  }

  Future<File> _file() async {
    final root = await _directoryProvider();
    final dir = Directory('${root.path}/$_subdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_fileName');
  }
}

/// The active [Outbox] used app-wide: file-backed in prod so queued
/// mutations survive a process restart, overridden with [InMemoryOutbox] in
/// tests (same pattern as [responseCacheProvider]).
final outboxProvider = Provider<Outbox>((ref) => FileOutbox());

/// Minimal reporting surface repositories/[SyncService] depend on to expose
/// the current pending-mutation count to the UI, without needing to import
/// Riverpod directly — mirrors [ConnectivityReporter]'s
/// data-layer-stays-framework-agnostic pattern.
abstract class PendingSyncReporter {
  void reportPendingCount(int count);
}

/// Default [PendingSyncReporter] for repositories/services built without an
/// explicit one (keeps constructors/tests working unchanged).
class NoopPendingSyncReporter implements PendingSyncReporter {
  const NoopPendingSyncReporter();

  @override
  void reportPendingCount(int count) {}
}

/// Tracks the app-wide pending-outbox count for the "N pendientes por
/// sincronizar" indicator. Updated by repositories on enqueue and by
/// [SyncService] as it drains — one app-wide count, not per-feature, same
/// design decision as [ConnectivityNotifier].
class PendingSyncCountNotifier extends Notifier<int> implements PendingSyncReporter {
  @override
  int build() => 0;

  @override
  void reportPendingCount(int count) => state = count;
}

final pendingSyncCountProvider = NotifierProvider<PendingSyncCountNotifier, int>(PendingSyncCountNotifier.new);
