// Proves the pairing form wires user input through to
// ConnectionNotifier.pair(), and that a failed pair renders the
// user-facing error message. No live engine — pairingRepositoryProvider is
// overridden with a fake.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/connection/data/pairing_repository.dart';
import 'package:lifeos/features/connection/presentation/connection_notifier.dart';
import 'package:lifeos/features/connection/presentation/connection_screen.dart';

import '../../../support/fake_token_store.dart';

class _FailingPairingRepository implements PairingRepository {
  @override
  Future<PairResult> pair({required String engineUrl, required String code, String deviceName = 'x'}) async {
    throw PairingException('El código de emparejamiento no es válido o ha expirado.');
  }
}

void main() {
  testWidgets('submitting the form with an invalid code shows the error message', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(FakeTokenStore()),
          pairingRepositoryProvider.overrideWithValue(_FailingPairingRepository()),
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
}
