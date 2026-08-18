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
    this.waitForMail = 0,
  })  : _engine = GraphSyncEngine(db),
        _db = db;

  final DatabaseExecutor _db;
  final GraphSyncEngine _engine;
  final SyncKeys keys;
  final String relayBaseUrl;

  /// Injected so a test can drive a fake relay. Null in production, where
  /// `RelayClient` builds its own.
  final Dio? dio;

  /// Seconds to let the relay HOLD an empty inbox fetch open.
  ///
  /// Zero for a background pass, which must finish and let the device sleep.
  /// Non-zero only while the app is open and someone is looking at it — that
  /// is the one moment where waiting a few seconds buys immediacy rather than
  /// battery.
  final int waitForMail;

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
    final board = await keys.sharedMailboxUuid();
    final inbox = await keys.deviceMailboxUuid(origin);

    try {
      // 1. ANNOUNCE. Say who we are on the shared board so devices that have
      //    never heard of us can compute our address.
      final boardRelay = await _relayFor(board);
      await boardRelay.claim();
      await _depositReplacing(
        boardRelay,
        board,
        await _engine.buildPayload(peerUuid: 'announce', limit: 0),
      );

      // 2. LISTEN. Collect every other device from the board.
      //
      //    Their announcements are NEVER acknowledged: on a shared board an ack
      //    deletes the message for everyone, and the third device would lose
      //    what the second happened to read first. Each device retires only its
      //    OWN announcement, by replacing it.
      for (final pending in await boardRelay.fetch()) {
        try {
          final payload =
              (await openEnvelope(dataKey: keys.dataKey, blob: pending.body))
                  .payload;
          final sender = payload['origin_device'] as String? ?? '';
          if (sender.isEmpty || sender == origin) continue;
          await _engine.rememberPeer(sender);
        } catch (_) {
          // Someone else's envelope we cannot open is not our problem to
          // report: it is not addressed to us and the board is shared.
          continue;
        }
      }

      // 3. RECEIVE. Our own mailbox has exactly one recipient, so acking is
      //    correct here and the envelope is genuinely consumed.
      final inboxRelay = await _relayFor(inbox);
      await inboxRelay.claim();

      var received = 0;
      var applied = 0;
      var conflicts = 0;

      // The inbox fetch is the one that WAITS. Our own board announcement and
      // the peers' mailboxes are checked and left; this is the request that
      // turns "the other device will find out on its next poll" into "the
      // other device already knows".
      for (final pending in await inboxRelay.fetch(waitSeconds: waitForMail)) {
        final payload =
            (await openEnvelope(dataKey: keys.dataKey, blob: pending.body))
                .payload;
        final sender = payload['origin_device'] as String? ?? '';
        if (sender == origin) {
          await inboxRelay.ack(pending.envId);
          continue;
        }

        received++;
        await _engine.rememberPeer(sender);
        final result = await _engine.applyPayload(payload, envId: pending.envId);
        applied += result.applied;
        conflicts += result.conflicts;

        final echo = payload['peer_cursor_echo'];
        if (echo is int) await _engine.recordEcho(sender, echo);

        // Acked only AFTER a successful apply: acking first would delete the
        // envelope while the rows were still not stored, and nothing would
        // ever resend them.
        await inboxRelay.ack(pending.envId);
      }

      // 4. SEND, once per peer, each into that peer's own mailbox.
      var sent = 0;
      for (final peer in await _engine.peers()) {
        final payload = await _engine.buildPayload(peerUuid: peer.uuid);
        final rows = (payload['rows']['nodes'] as List).length +
            (payload['rows']['edges'] as List).length;
        // Also sent when we merely APPLIED something: our echo rides on the
        // payload, and without it the peer never advances its cursor and
        // resends the same rows on every pass, for ever.
        if (rows == 0 && applied == 0) continue;
        final target = await keys.deviceMailboxUuid(peer.uuid);
        final peerRelay = await _relayFor(target);
        await peerRelay.claim();
        await _depositReplacing(peerRelay, target, payload);
        sent += rows;
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

  Future<RelayClient> _relayFor(String mailbox) async => RelayClient(
        baseUrl: relayBaseUrl,
        mailboxUuid: mailbox,
        authKeyPair: await keys.mailboxAuthKeyPair(mailbox),
        dio: dio,
      );

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
    final previous = await lastDepositTo(_db, mailbox);
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
    await rememberDepositTo(_db, mailbox, envId);

    if (previous != null && previous != envId) {
      // Best-effort: a failure here leaves one extra envelope to expire on the
      // relay's own TTL, which is strictly better than deleting a live one.
      try {
        await relay.ack(previous);
      } catch (_) {}
    }
  }

  /// The first pass a brand-new device makes, announcing itself so the others
  /// can compute its address.
  Future<void> announce() async {
    final board = await keys.sharedMailboxUuid();
    final relay = await _relayFor(board);
    await relay.claim();
    await _depositReplacing(
      relay,
      board,
      await _engine.buildPayload(peerUuid: 'announce', limit: 0),
    );
  }
}

/// Human-readable outcome for the settings screen.
String describeSyncPass(SyncPassReport report) {
  if (report.failure != null) return report.failure!;
  if (report.applied == 0 && report.sent == 0) return 'Todo estaba al día.';
  return 'Recibí ${report.applied} y envié ${report.sent}.'
      '${report.conflicts > 0 ? ' ${report.conflicts} en conflicto.' : ''}';
}

/// The payload as it travels. Exposed for tests that need to assert the wire
/// shape without a relay.
String encodeSyncPayload(Map<String, dynamic> payload) => jsonEncode(payload);
