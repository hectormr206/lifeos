// Proves the off-device backup screen is reachable AND that it did not take
// over `/settings/backups` — that path already belongs to the on-device backup
// list, and shadowing it would silently remove the restore flow.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/backup/presentation/backup_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_token_store.dart';

Future<void> _goTo(
  WidgetTester tester,
  ProviderContainer container,
  String location,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const LifeOSApp()),
  );
  await tester.pump();
  container.read(goRouterProvider).go(location);
  // Bounded pumps, not pumpAndSettle: the screen loads its stored config
  // asynchronously and shows a spinner meanwhile.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      // Otherwise the first-launch gate redirects every route to /onboarding.
      'onboarding_permissions_done': true,
    });
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('/settings/backups/server renders the server screen',
      (tester) async {
    final container = ProviderContainer(
      overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
    );
    addTearDown(container.dispose);

    await _goTo(tester, container, '/settings/backups/server');

    expect(find.byType(BackupSettingsScreen), findsOneWidget);
  });

  testWidgets('/settings/backups still renders the on-device list, unshadowed',
      (tester) async {
    final container = ProviderContainer(
      overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
    );
    addTearDown(container.dispose);

    await _goTo(tester, container, '/settings/backups');

    // The parent route must NOT resolve to the server screen: a collision
    // there would remove the restore flow without any test noticing.
    expect(find.byType(BackupSettingsScreen), findsNothing);
  });
}
