// Proves the one-time permissions-onboarding flag reads/writes correctly and
// defaults to false when never set — using shared_preferences' in-memory mock
// backing (no real platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to false (onboarding not done) when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsOnboardingPreferences();
    expect(await prefs.isPermissionsOnboardingDone(), isFalse);
  });

  test('marking done persists true and reads back', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsOnboardingPreferences();

    await prefs.markPermissionsOnboardingDone();

    expect(await prefs.isPermissionsOnboardingDone(), isTrue);
  });

  test('reads an existing persisted true', () async {
    SharedPreferences.setMockInitialValues(
      {SharedPrefsOnboardingPreferences.doneKey: true},
    );
    final prefs = SharedPrefsOnboardingPreferences();
    expect(await prefs.isPermissionsOnboardingDone(), isTrue);
  });
}
