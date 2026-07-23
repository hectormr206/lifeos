// Proves the onboarding gate notifier: starts `unknown`, hydrates to
// `pending`/`done` from persistence, fails safe to `done` on a prefs error, and
// `complete()` transitions to `done` + persists. Uses a fake
// OnboardingPreferences (no platform channel).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/permissions/domain/onboarding_preferences.dart';
import 'package:lifeos/features/permissions/presentation/permissions_providers.dart';

class _FakeOnboardingPreferences implements OnboardingPreferences {
  _FakeOnboardingPreferences({this.done = false, this.throwOnRead = false});

  bool done;
  final bool throwOnRead;
  int marks = 0;

  @override
  Future<bool> isPermissionsOnboardingDone() async {
    if (throwOnRead) throw Exception('no channel');
    return done;
  }

  @override
  Future<void> markPermissionsOnboardingDone() async {
    marks++;
    done = true;
  }
}

ProviderContainer _container(OnboardingPreferences prefs) {
  final container = ProviderContainer(
    overrides: [onboardingPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('starts unknown then hydrates to pending when never onboarded', () async {
    final container = _container(_FakeOnboardingPreferences(done: false));

    expect(container.read(onboardingGateProvider), OnboardingGate.unknown);

    await container.read(onboardingGateProvider.notifier).ready;

    expect(container.read(onboardingGateProvider), OnboardingGate.pending);
  });

  test('hydrates to done when already onboarded', () async {
    final container = _container(_FakeOnboardingPreferences(done: true));

    await container.read(onboardingGateProvider.notifier).ready;

    expect(container.read(onboardingGateProvider), OnboardingGate.done);
  });

  test('fails safe to done when persistence throws', () async {
    final container = _container(_FakeOnboardingPreferences(throwOnRead: true));

    await container.read(onboardingGateProvider.notifier).ready;

    expect(container.read(onboardingGateProvider), OnboardingGate.done);
  });

  test('complete() transitions to done and persists the flag', () async {
    final prefs = _FakeOnboardingPreferences(done: false);
    final container = _container(prefs);
    await container.read(onboardingGateProvider.notifier).ready;
    expect(container.read(onboardingGateProvider), OnboardingGate.pending);

    await container.read(onboardingGateProvider.notifier).complete();

    expect(container.read(onboardingGateProvider), OnboardingGate.done);
    expect(prefs.marks, 1);
  });
}
