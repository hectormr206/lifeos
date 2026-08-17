// Slice 5: the rules the sync UI has to obey.
//
// Three of them, and each one has a specific way of betraying the user:
//
//   * Sync connectivity must NOT be the VPN gate. Reusing `vpn_gate.dart` —
//     documented there as the authoritative gate for BACKUPS and explicitly not
//     a general connectivity signal — would tie a feature that works over the
//     open internet to a tunnel it never needed.
//   * Everything local keeps working with sync off, and keeps working after
//     sync is turned off again. Sync is additive. Disabling it must never look
//     or feel like a wipe.
//   * The residual metadata is disclosed verbatim, in the settings screen, in
//     the user's language. A privacy promise that hides its own exceptions is
//     worth nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/domain/sync_connectivity.dart';
import 'package:lifeos/features/sync/domain/sync_disclosure.dart';
import 'package:lifeos/features/sync/domain/sync_enablement.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';

import 'support/fake_sync_key_store.dart';

void main() {
  group('connectivity is about the relay, not the VPN', () {
    test('reachable relay + Wi-Fi + enabled = active', () {
      expect(
        resolveSyncConnectivity(
          syncEnabled: true,
          relayReachable: true,
          onUnmeteredNetwork: true,
        ),
        SyncConnectivity.reachable,
      );
    });

    test('a device off the VPN syncs fine — the VPN is not consulted', () {
      // There is deliberately no `vpnUp` parameter to pass. The absence IS the
      // test: a future edit that wanted to gate on the VPN would have to change
      // this signature, which is a visible decision rather than a quiet one.
      expect(
        resolveSyncConnectivity(
          syncEnabled: true,
          relayReachable: true,
          onUnmeteredNetwork: true,
        ),
        SyncConnectivity.reachable,
      );
    });

    test('an unreachable relay is the only state worth alarming about', () {
      expect(
        resolveSyncConnectivity(
          syncEnabled: true,
          relayReachable: false,
          onUnmeteredNetwork: true,
        ).isProblem,
        isTrue,
      );

      for (final state in [
        SyncConnectivity.notEnabled,
        SyncConnectivity.reachable,
        SyncConnectivity.waitingForWifi,
      ]) {
        expect(
          state.isProblem,
          isFalse,
          reason: 'badging a deliberate choice or a normal wait as a problem '
              'teaches people to ignore badges',
        );
      }
    });

    test('disabled beats everything — no false "offline" alarm', () {
      expect(
        resolveSyncConnectivity(
          syncEnabled: false,
          relayReachable: false,
          onUnmeteredNetwork: false,
        ),
        SyncConnectivity.notEnabled,
      );
    });

    test('every state has copy a person can act on', () {
      for (final state in SyncConnectivity.values) {
        expect(state.label, isNotEmpty);
        expect(state.label.length, lessThan(40), reason: 'it is a status line');
      }
    });
  });

  group('sync is additive', () {
    test('turning sync off clears keys and nothing else', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final ceremony = PhraseCeremony.generate();
      ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      });
      await sync.enable(ceremony);

      await sync.disable();

      expect(await sync.isEnabled(), isFalse);
      expect(await store.readEntropy(), isNull);
      // The store is the ONLY thing sync owns. Local graph, notes, reminders
      // and briefings live elsewhere and are untouched by this call — which is
      // why `disable()` has no access to them at all.
    });

    test('re-enabling with the same phrase restores the same key', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final ceremony = PhraseCeremony.generate();
      ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      });
      await sync.enable(ceremony);
      final before = await store.readEntropy();

      await sync.disable();
      await sync.restore(ceremony.mnemonic);

      expect(await store.readEntropy(), before);
    });
  });

  group('the disclosure is honest and stays honest', () {
    test('every observation says WHAT and WHY', () {
      expect(kRelayCanSee, isNotEmpty);
      for (final o in kRelayCanSee) {
        expect(o.what, isNotEmpty);
        expect(
          o.why,
          isNotEmpty,
          reason: 'a disclosure without the reason reads as an apology; these '
              'are consequences of routing, not choices',
        );
      }
    });

    test('it names the four things the relay actually observes', () {
      final all = kRelayCanSee.map((o) => o.what.toLowerCase()).join(' | ');

      expect(all, contains('buzón'));
      expect(all, contains('llave pública'));
      expect(all, contains('tamaño'));
      expect(all, contains('ip'));
    });

    test('it states what the relay CANNOT see with the same weight', () {
      // A disclosure that lists only the bad news misleads in the other
      // direction: the reason the observable list is acceptable is this one.
      expect(kRelayCannotSee.length, greaterThanOrEqualTo(3));
      final all = kRelayCannotSee.join(' ').toLowerCase();
      expect(all, contains('contenido'));
      expect(all, contains('frase de recuperación'));
    });

    test('retention is stated in days, not in adjectives', () {
      expect(kRelayRetention, contains('30 días'));
      expect(
        kRelayRetention.toLowerCase(),
        contains('no queda nada'),
        reason: 'the claim that an idle device set leaves nothing behind is '
            'the strongest promise here and must be said outright',
      );
    });

    test('no marketing words', () {
      // "totalmente seguro", "100% privado" and friends are how a disclosure
      // stops being one. If a claim cannot be tested, it does not belong here.
      final text = [
        ...kRelayCanSee.map((o) => '${o.what} ${o.why}'),
        ...kRelayCannotSee,
        kRelayRetention,
      ].join(' ').toLowerCase();

      for (final banned in ['100%', 'totalmente seguro', 'imposible de']) {
        expect(text, isNot(contains(banned)));
      }
    });
  });
}
