// Proves the pairing form wires user input through to
// ConnectionNotifier.pair(), and that a failed pair renders the
// user-facing error message. No live engine — pairingRepositoryProvider is
// overridden with a fake.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/tls/tls_trust_decision.dart';
import 'package:lifeos/features/connection/data/ca_provisioning_repository.dart';
import 'package:lifeos/features/connection/data/pairing_repository.dart';
import 'package:lifeos/features/connection/presentation/connection_notifier.dart';
import 'package:lifeos/features/connection/presentation/connection_screen.dart';

import '../../../support/fake_token_store.dart';

class _FailingPairingRepository implements PairingRepository {
  @override
  Future<PairResult> pair({
    required String engineUrl,
    required String code,
    String deviceName = 'x',
    TlsTrustDecision trust = TlsTrustDecision.none,
  }) async {
    throw PairingException('El código de emparejamiento no es válido o ha expirado.');
  }
}

class _SucceedingPairingRepository implements PairingRepository {
  TlsTrustDecision? lastTrust;

  @override
  Future<PairResult> pair({
    required String engineUrl,
    required String code,
    String deviceName = 'x',
    TlsTrustDecision trust = TlsTrustDecision.none,
  }) async {
    lastTrust = trust;
    return PairResult(engineUrl: engineUrl, token: 'tok', deviceId: 'dev-1');
  }
}

class _FailingCaProvisioningRepository implements CaProvisioningRepository {
  @override
  Future<FetchedCaCertificate> fetchRootCa(String engineUrl) async {
    throw CaProvisioningException('sin CA disponible');
  }
}

class _SucceedingCaProvisioningRepository implements CaProvisioningRepository {
  @override
  Future<FetchedCaCertificate> fetchRootCa(String engineUrl) async => FetchedCaCertificate(
        pem: '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----',
        der: Uint8List(0),
        fingerprint: 'fingerprint',
      );
}

void main() {
  testWidgets('submitting the form with an invalid code shows the error message', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          pairingRepositoryProvider.overrideWithValue(_FailingPairingRepository()),
          caProvisioningRepositoryProvider.overrideWithValue(_SucceedingCaProvisioningRepository()),
        ],
        child: const MaterialApp(home: ConnectionScreen()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'URL del motor'), 'https://10.66.66.2:8081');
    await tester.enterText(find.widgetWithText(TextField, 'Código de emparejamiento'), 'BAD');
    await tester.tap(find.text('Emparejar'));
    await tester.pump();
    await tester.pump();

    expect(find.text('El código de emparejamiento no es válido o ha expirado.'), findsOneWidget);
  });

  testWidgets('shows the optional ca_fp field and the dev self-signed toggle', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: const MaterialApp(home: ConnectionScreen()),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(TextField, 'ca_fp (opcional)'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.textContaining('autofirmado'), findsOneWidget);
  });

  testWidgets('the dev self-signed toggle is off by default and pairs without it unset', (tester) async {
    final pairing = _SucceedingPairingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          pairingRepositoryProvider.overrideWithValue(pairing),
          caProvisioningRepositoryProvider.overrideWithValue(_FailingCaProvisioningRepository()),
        ],
        child: const MaterialApp(home: ConnectionScreen()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'URL del motor'), 'https://10.66.66.2:8081');
    await tester.enterText(find.widgetWithText(TextField, 'Código de emparejamiento'), 'ABC123');
    await tester.tap(find.text('Emparejar'));
    await tester.pump();
    await tester.pump();

    // No CA could be fetched and the dev toggle was never enabled -> Error,
    // never a silent pair.
    expect(find.textContaining('confiar en servidor autofirmado'), findsWidgets);
  });

  testWidgets('enabling the dev self-signed toggle lets pairing succeed with no CA', (tester) async {
    final pairing = _SucceedingPairingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          pairingRepositoryProvider.overrideWithValue(pairing),
          caProvisioningRepositoryProvider.overrideWithValue(_FailingCaProvisioningRepository()),
        ],
        child: const MaterialApp(home: ConnectionScreen()),
      ),
    );
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'URL del motor'), 'https://10.66.66.2:8081');
    await tester.enterText(find.widgetWithText(TextField, 'Código de emparejamiento'), 'ABC123');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Emparejar'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Motor: https://10.66.66.2:8081'), findsOneWidget);
    expect(pairing.lastTrust?.trustSelfSigned, isTrue);
  });
}
