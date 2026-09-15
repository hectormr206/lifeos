import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/outbox/pending_sync_reporting.dart';

import '../../support/outbox_test_doubles.dart';

class _UnreadableOutbox extends InMemoryOutbox {
  _UnreadableOutbox(this.error);

  final Object error;

  @override
  Future<List<OutboxEntry>> list() async => throw error;
}

class _ThrowingReporter implements PendingSyncReporter {
  _ThrowingReporter(this.error);

  final Object error;
  final List<int> calls = [];

  @override
  void reportPendingCount(int count) {
    calls.add(count);
    throw error;
  }
}

void main() {
  test('reports the available pending count, including a valid empty queue', () async {
    final outbox = InMemoryOutbox();
    final reporter = RecordingPendingSyncReporter();
    await outbox.enqueue(httpMethod: 'POST', path: '/test');

    await reportPendingCountIfAvailable(outbox, reporter);
    expect(reporter.count, 1);
    final entry = (await outbox.list()).single;
    await outbox.remove(entry.id);
    await reportPendingCountIfAvailable(outbox, reporter);

    expect(reporter.count, 0);
    expect(reporter.reports, [1, 0]);
  });

  test('storage read failure preserves the prior count without reporting', () async {
    final reporter = RecordingPendingSyncReporter();

    await reportPendingCountIfAvailable(
      _UnreadableOutbox(const OutboxStorageException()),
      reporter,
    );

    expect(reporter.count, 7);
    expect(reporter.reports, isEmpty);
  });

  test('non-storage read failure propagates without reporting', () async {
    final error = StateError('unexpected read failure');
    final reporter = RecordingPendingSyncReporter();

    await expectLater(
      reportPendingCountIfAvailable(_UnreadableOutbox(error), reporter),
      throwsA(same(error)),
    );

    expect(reporter.count, 7);
    expect(reporter.reports, isEmpty);
  });

  for (final error in [
    StateError('reporter failure'),
    const OutboxStorageException(),
  ]) {
    test('reporter ${error.runtimeType} propagates outside the read catch', () async {
      final reporter = _ThrowingReporter(error);

      await expectLater(
        reportPendingCountIfAvailable(InMemoryOutbox(), reporter),
        throwsA(same(error)),
      );

      expect(reporter.calls, [0]);
    });
  }
}
