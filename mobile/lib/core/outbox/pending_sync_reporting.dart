import 'outbox.dart';

/// Count telemetry must not turn an already accepted mutation into a failure.
/// An unavailable read leaves the reporter's previous count unchanged.
Future<void> reportPendingCountIfAvailable(
  Outbox outbox,
  PendingSyncReporter reporter,
) async {
  final List<OutboxEntry> entries;
  try {
    entries = await outbox.list();
  } on OutboxStorageException {
    return;
  }
  // Reporter failures are not storage-read failures, even with the same type.
  reporter.reportPendingCount(entries.length);
}
