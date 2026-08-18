// One complete sync pass: fetch, apply, send.
//
// This is the piece that was missing while everything else was green. The
// engine, the relay client, the envelope and the scheduler all existed and all
// passed their own suites; nothing called them. A feature is not the sum of its
// tested parts — it is the call that joins them, and that call had never been
// written.
//
// Order matters and is not arbitrary: RECEIVE FIRST, then send. Applying the
// peer's rows before building our own payload lifts our Lamport high-water mark
// past theirs, so our next write cannot collide with a value they already used.
// Sending first would work too, but every pass would carry one extra round of
// avoidable conflicts.
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:lifeos/core/sync/envelope.dart';
import 'package:lifeos/core/sync/keys.dart';
import 'package:lifeos/core/sync/relay_client.dart';
import 'package:lifeos/core/sync/stamping.dart';
import 'package:lifeos/features/sync/data/graph_sync_engine.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// Why a pass ended the way it did. Every field is something the UI is allowed
/// to say out loud — a pass that fails must never render as "listo".
class SyncPassReport {
  const SyncPassReport({
    required this.received,
    required this.applied,
    required this.sent,
    required this.conflicts,
    this.failure,
    this.tooManyDevices = false,
  });

  final int received;
  final int applied;
  final int sent;
  final int conflicts;

  /// Set when the pass could not complete. Present means FAILED, and the caller
  /// must show it rather than a success state.
  final String? failure;

  /// The shared mailbox cannot serve three devices (see
  /// [SyncKeys.sharedMailboxUuid]). Reported loudly instead of syncing a third
  /// device wrongly and silently.
  final bool tooManyDevices;

  bool get ok => failure == null && !tooManyDevices;
}

class SyncPass {
  SyncPass({
    required DatabaseExecutor db,
    required this.keys,
    required this.relayBaseUrl,
    this.dio,
  })  : _engine = GraphSyncEngine(db),
        _db = db;

  final DatabaseExecutor _db;
  final GraphSyncEngine _engine;
  final SyncKeys keys;
  final String relayBaseUrl;

  /// Injected so a test can drive a fake relay. Null in production, where
  /// `RelayClient` builds its own.
  final Dio? dio;

  Future<SyncPassReport> run() async {
    if (relayBaseUrl.isEmpty) {
      return const SyncPassReport(
        received: 0,
        applied: 0,
        sent: 0,
        conflicts: 0,
        failure: 'No hay servidor de sincronización configurado.',
      );
    }

    await _engine.ensureReady();
    final origin = await localOrigin(_db);
    final mailbox = await keys.sharedMailboxUuid();
    final authKeyPair = await keys.mailboxAuthKeyPair(mailbox);

    final relay = RelayClient(
      baseUrl: relayBaseUrl,
      mailboxUuid: mailbox,
      authKeyPair: authKeyPair,
      dio: dio,
    );

    try {
      // Idempotent for the same key, and the key comes from the phrase — so a
      // device that reinstalled and restored is not locked out of its own
      // mailbox at the exact moment the phrase is supposed to save it.
      await relay.claim();

      var received = 0;
      var applied = 0;
      var conflicts = 0;
      final peers = <String>{};

      for (final pending in await relay.fetch()) {
        final opened = await openEnvelope(
          dataKey: keys.dataKey,
          blob: pending.body,
        );
        final payload = opened.payload;
        final sender = payload['origin_device'] as String? ?? '';

        // Our own envelope coming back: the mailbox is shared, so we see what
        // we deposited. SKIPPED, never acknowledged.
        //
        // Acknowledging it deletes it at the relay — and that is precisely the
        // message the other device still has to read. The device that synced
        // first destroyed the other's only way to learn it existed, and both
        // then reported "todavía no hay otro dispositivo" for ever. Our own
        // envelope is retired only when we deposit its replacement.
        if (sender == origin) continue;

        peers.add(sender);
        received++;

        final result = await _engine.applyPayload(payload, envId: pending.envId);
        applied += result.applied;
        conflicts += result.conflicts;

        // The sender told us how far IT has applied of OUR rows; that is the
        // only thing allowed to advance our cursor for it.
        final echo = payload['peer_cursor_echo'];
        if (echo is int) await _engine.recordEcho(sender, echo);

        // Acked only AFTER a successful apply. Acking first would delete the
        // envelope from the relay while the rows were still not stored, and
        // nothing would ever resend them.
        await relay.ack(pending.envId);
      }

      if (peers.length > 1) {
        return SyncPassReport(
          received: received,
          applied: applied,
          sent: 0,
          conflicts: conflicts,
          tooManyDevices: true,
        );
      }

      final peer = peers.isEmpty ? null : peers.first;
      var sent = 0;

      // With NO peer known we still deposit, announcing ourselves.
      //
      // Waiting for a peer before depositing is a deadlock: each device sits
      // silent waiting for a message the other is equally waiting to receive.
      // That is the state two installs end up in after any envelope loss, and
      // it must resolve itself — a user should never have to reinstall or
      // retype the phrase to recover.
      final payload = await _engine.buildPayload(peerUuid: peer ?? 'announce');
      final nodes = (payload['rows']['nodes'] as List).length;
      final edges = (payload['rows']['edges'] as List).length;

      // Also deposit when we merely APPLIED something: our echo rides on the
      // payload, and without it the peer never advances its cursor and resends
      // the same rows on every pass, for ever.
      if (peer == null || nodes + edges > 0 || applied > 0) {
        sent = nodes + edges;
        await _depositReplacing(relay, mailbox, payload);
      }

      return SyncPassReport(
        received: received,
        applied: applied,
        sent: sent,
        conflicts: conflicts,
      );
    } on RelayError catch (e) {
      return SyncPassReport(
        received: 0,
        applied: 0,
        sent: 0,
        conflicts: 0,
        failure: 'El servidor rechazó la sincronización (${e.statusCode}).',
      );
    } catch (e) {
      // Deliberately broad, and deliberately NOT swallowed: a pass that dies
      // must say so. Reporting "listo" after a failure is the exact behaviour
      // this codebase forbids.
      return SyncPassReport(
        received: 0,
        applied: 0,
        sent: 0,
        conflicts: 0,
        failure: 'No se pudo sincronizar: $e',
      );
    }
  }

  /// Deposit a payload and retire the envelope this device left last time.
  ///
  /// Retiring the OLD one only after the NEW one is stored means the mailbox
  /// always holds something from us for the peer to find, while never
  /// accumulating one envelope per pass.
  Future<void> _depositReplacing(
    RelayClient relay,
    String mailbox,
    Map<String, dynamic> payload,
  ) async {
    final previous = await lastDeposit(_db);
    final envelope = await sealEnvelope(
      dataKey: keys.dataKey,
      recipientUuid: mailbox,
      payload: payload,
    );
    await relay.deposit(envelope);

    // The env id is bytes 1..33 of the sealed blob, the same slice the relay
    // keys it by.
    final envId = [
      for (final b in envelope.sublist(1, 33)) b.toRadixString(16).padLeft(2, '0'),
    ].join();
    await rememberDeposit(_db, envId);

    if (previous != null && previous != envId) {
      // Best-effort: a failure here leaves one extra envelope to expire on the
      // relay's own TTL, which is strictly better than deleting a live one.
      try {
        await relay.ack(previous);
      } catch (_) {}
    }
  }

  /// The first pass a brand-new device makes, announcing itself so the peer
  /// learns its origin. Without it two devices that have never spoken would
  /// each wait for the other to go first.
  Future<void> announce() async {
    final mailbox = await keys.sharedMailboxUuid();
    final relay = RelayClient(
      baseUrl: relayBaseUrl,
      mailboxUuid: mailbox,
      authKeyPair: await keys.mailboxAuthKeyPair(mailbox),
      dio: dio,
    );
    await relay.claim();
    await _depositReplacing(
      relay,
      mailbox,
      await _engine.buildPayload(peerUuid: 'announce'),
    );
  }
}

/// Human-readable outcome for the settings screen.
String describeSyncPass(SyncPassReport report) {
  if (report.tooManyDevices) {
    return 'Por ahora la sincronización funciona entre dos dispositivos. '
        'Detecté más y me detuve para no mezclar tu información.';
  }
  if (report.failure != null) return report.failure!;
  if (report.applied == 0 && report.sent == 0) return 'Todo estaba al día.';
  return 'Recibí ${report.applied} y envié ${report.sent}.'
      '${report.conflicts > 0 ? ' ${report.conflicts} en conflicto.' : ''}';
}

/// The payload as it travels. Exposed for tests that need to assert the wire
/// shape without a relay.
String encodeSyncPayload(Map<String, dynamic> payload) => jsonEncode(payload);
