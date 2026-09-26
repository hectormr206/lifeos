import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';
import 'package:lifeos/features/domains/data/domain_repository.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'probe_result.dart';
import 'probe_progress.dart';
import 'probe_storage.dart';

bool _telemetryClaimed = false;

/// Real repository and durable outbox; only transport/count/callback are faulted.
/// The caller must first finish every CORE scenario successfully.
Stream<ProbeResult> runTelemetryProbe(ProbeProgress progress) async* {
  if (_telemetryClaimed) {
    yield const ProbeResult(
      'telemetry_run_guard', ProbeStatus.blocked, 0, ProbeCategory.safetyGuard,
    );
    return;
  }
  _telemetryClaimed = true;
  for (final callbackFailure in [false, true]) {
    final result = await progress.measure(
      callbackFailure
          ? 'telemetry_callback_error_persisted'
          : 'telemetry_count_unavailable_accepted',
      () => _exercise(callbackFailure),
    );
    yield result;
    if (result.status != ProbeStatus.passed) return;
  }
}

Future<List<int>?> _exercise(bool callbackFailure) async {
  await requireProbePackage();
  const secure = FlutterSecureStorage();
  const slot = 'lifeos.auxiliary_files.aes256gcm_key';
  if (await secure.read(key: slot) != null) throw ProbeBlocked();
  final support = await getApplicationSupportDirectory();
  await for (final entity in support.list()) {
    if (entity.uri.pathSegments.any((p) => p.startsWith('security-probe-'))) {
      throw ProbeBlocked();
    }
  }
  final root = await support.createTemp('security-probe-telemetry-');
  FileOutbox fresh() => FileOutbox(
    cipher: EncryptedFileCipher(),
    directoryProvider: () async => root,
  );
  final wrapped = _CountFaultOutbox(fresh(), !callbackFailure);
  final reporter = _Reporter(callbackFailure);
  final adapter = _OfflineTransport();
  final dio = Dio(BaseOptions(baseUrl: 'https://probe.invalid'))
    ..httpClientAdapter = adapter;
  final descriptor = domainDescriptors.first;
  const body = {'title': 'synthetic-probe', 'ts': '2026-01-01T00:00:00Z'};
  var callbackObserved = false;
  try {
    final entry = await HttpDomainRepository(
      dio,
      outbox: wrapped,
      pendingSync: reporter,
    ).createEntry(descriptor, body);
    probeRequire(!callbackFailure && entry.id.startsWith('local-'));
    probeRequire(entry.title == body['title'] && jsonEncode(entry.raw) ==
        jsonEncode(body));
  } on OutboxStorageException catch (error) {
    probeRequire(callbackFailure && identical(error, reporter.failure));
    callbackObserved = true;
  } finally {
    dio.close(force: true);
  }
  probeRequire(callbackObserved == callbackFailure && adapter.calls == 1);
  probeRequire(wrapped.accepted != null && wrapped.countReads == 1);
  probeRequire(reporter.count == 7);
  probeRequire(reporter.calls == (callbackFailure ? 1 : 0));
  final key = await secure.read(key: slot);
  probeRequire(key != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(key));
  final file = File('${root.path}/outbox/outbox.json');
  final bytes = await file.readAsBytes();
  probeRequire(EncryptedFileCipher().isEncrypted(bytes));
  final entries = await fresh().list();
  probeRequire(entries.length == 1);
  final persisted = entries.single;
  probeRequire(persisted.httpMethod == 'POST' &&
      persisted.path == descriptor.listPath &&
      persisted.kind == '${descriptor.key}_create');
  probeRequire(jsonEncode(persisted.jsonBody) == jsonEncode(body));
  probeRequire(jsonEncode(persisted.toJson()) ==
      jsonEncode(wrapped.accepted!.toJson()));
  probeRequire(await fixtureHash(await file.readAsBytes()) ==
      await fixtureHash(bytes));
  probeRequire(await secure.read(key: slot) == key);
  // Successful fresh recovery proves ownership before deleting only our data.
  // On any earlier failure, leave artifacts intact so the next run blocks.
  await root.delete(recursive: true);
  await secure.delete(key: slot);
  probeRequire(await secure.read(key: slot) == null);
  return bytes;
}

class _CountFaultOutbox implements Outbox {
  _CountFaultOutbox(this.inner, this.failCount);

  final FileOutbox inner;
  final bool failCount;
  OutboxEntry? accepted;
  int countReads = 0;

  @override
  Future<OutboxEntry> enqueue({
    required String httpMethod,
    required String path,
    Map<String, Object?>? jsonBody,
    String? kind,
  }) async {
    final entry = await inner.enqueue(
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
    probeRequire(accepted != null);
    countReads++;
    if (failCount) throw const OutboxStorageException();
    return inner.list();
  }

  @override
  Future<void> remove(String id) => inner.remove(id);
}

class _Reporter implements PendingSyncReporter {
  _Reporter(this.fail);

  final bool fail;
  final failure = const OutboxStorageException();
  int count = 7;
  int calls = 0;

  @override
  void reportPendingCount(int value) {
    calls++;
    probeRequire(value == 1);
    if (fail) throw failure;
    count = value;
  }
}

/// No socket is ever opened, even if platform network access is available.
class _OfflineTransport implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'synthetic transport failure',
    );
  }

  @override
  void close({bool force = false}) {}
}
