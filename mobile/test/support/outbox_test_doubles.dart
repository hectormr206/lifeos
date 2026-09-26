import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';

/// Real encrypted persistence, with a fault only at the reporting read boundary.
class ReportingReadFailureOutbox implements Outbox {
  ReportingReadFailureOutbox(this.directory);

  final Directory directory;
  final EncryptedFileCipher _cipher = EncryptedFileCipher(
    keyProvider: () async => SecretKey(List<int>.filled(32, 42)),
  );
  final storageError = const OutboxStorageException();
  bool rejectEnqueue = false;
  int enqueueCalls = 0;
  int listCalls = 0;
  OutboxEntry? accepted;

  FileOutbox reopen() => FileOutbox(
    directoryProvider: () async => directory,
    cipher: _cipher,
  );

  static Future<ReportingReadFailureOutbox> create() async {
    final directory = await Directory.systemTemp.createTemp('outbox-reporting-');
    addTearDown(() => directory.delete(recursive: true));
    return ReportingReadFailureOutbox(directory);
  }

  @override
  Future<OutboxEntry> enqueue({
    required String httpMethod,
    required String path,
    Map<String, Object?>? jsonBody,
    String? kind,
  }) async {
    enqueueCalls++;
    if (rejectEnqueue) throw storageError;
    final entry = await reopen().enqueue(
      httpMethod: httpMethod,
      path: path,
      jsonBody: jsonBody,
      kind: kind,
    );
    accepted = entry;
    return entry;
  }

  @override
  Future<List<OutboxEntry>> list() async {
    listCalls++;
    if (accepted == null) throw StateError('Count read before durable enqueue');
    throw storageError;
  }

  @override
  Future<void> remove(String id) => reopen().remove(id);
}

class RecordingPendingSyncReporter implements PendingSyncReporter {
  int count = 7;
  final List<int> reports = [];

  @override
  void reportPendingCount(int value) {
    count = value;
    reports.add(value);
  }
}

/// Apply the same acceptance boundary to each repository operation, not a fake
/// mutation: only HTTP transport and the post-enqueue count read are faulted.
void pendingCountFailureTests<T>({
  required String operation,
  required Future<T> Function(Outbox, PendingSyncReporter) mutate,
  required void Function(T) expectSuccess,
  required String httpMethod,
  required String path,
  required String kind,
  Map<String, Object?>? jsonBody,
}) {
  group('$operation pending count telemetry', () {
    test('keeps queued success when the post-enqueue count read fails', () async {
      final outbox = await ReportingReadFailureOutbox.create();
      final reporter = RecordingPendingSyncReporter();

      try {
        expectSuccess(await mutate(outbox, reporter));
      } finally {
        // Also verify durable acceptance on RED, when the mutation throws.
        final recovered = await outbox.reopen().list();
        expect(outbox.enqueueCalls, 1);
        expect(outbox.accepted, isNotNull);
        expect(recovered, hasLength(1));
        expect(recovered.single.toJson(), outbox.accepted!.toJson());
        expect(recovered.single.httpMethod, httpMethod);
        expect(recovered.single.path, path);
        expect(recovered.single.kind, kind);
        expect(recovered.single.jsonBody, jsonBody);
        expect(outbox.listCalls, 1);
        expect(reporter.count, 7);
        expect(reporter.reports, isEmpty);
      }
    });

    test('propagates enqueue storage failure without reporting success', () async {
      final outbox = await ReportingReadFailureOutbox.create();
      outbox.rejectEnqueue = true;
      final reporter = RecordingPendingSyncReporter();

      await expectLater(
        mutate(outbox, reporter),
        throwsA(same(outbox.storageError)),
      );

      expect(outbox.enqueueCalls, 1);
      expect(outbox.accepted, isNull);
      expect(await outbox.reopen().list(), isEmpty);
      expect(outbox.listCalls, 0);
      expect(reporter.count, 7);
      expect(reporter.reports, isEmpty);
    });
  });
}
