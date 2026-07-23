import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/permission_handler_permissions_gateway.dart';
import '../domain/app_permission.dart';
import '../domain/onboarding_preferences.dart';
import '../domain/permissions_gateway.dart';

/// Reusable permissions gateway (permission_handler). Overridden with a fake in
/// tests. Any feature can `ref.read(permissionsGatewayProvider)` to query or
/// request a permission.
final permissionsGatewayProvider = Provider<PermissionsGateway>(
  (ref) => const PermissionHandlerPermissionsGateway(),
);

/// Persistence for the one-time onboarding flag. Overridden with a fake in
/// tests.
final onboardingPreferencesProvider = Provider<OnboardingPreferences>(
  (ref) => SharedPrefsOnboardingPreferences(),
);

/// Live status of a single [AppPermission]. `autoDispose` + `family` so each
/// Settings tile watches its own permission and re-reads when invalidated (the
/// Settings screen invalidates the whole family on resume).
final permissionStatusProvider =
    FutureProvider.autoDispose.family<PermissionState, AppPermission>(
  (ref, permission) => ref.watch(permissionsGatewayProvider).status(permission),
);

/// First-launch onboarding gate state.
enum OnboardingGate {
  /// Persistence not yet read — the router must NOT redirect to onboarding
  /// (avoids trapping an already-onboarded user during the async hydrate).
  unknown,

  /// Never onboarded — the router redirects to `/onboarding`.
  pending,

  /// Onboarding completed or skipped — normal routing.
  done,
}

/// Synchronous onboarding gate for the GoRouter redirect (default [unknown],
/// hydrated from persistence). Mirrors the async-hydrate pattern of
/// [themeModeProvider] / [localModelEnabledProvider]: the router reads it
/// without awaiting and reacts once hydration flips it to [pending]/[done].
final onboardingGateProvider =
    NotifierProvider<OnboardingGateNotifier, OnboardingGate>(OnboardingGateNotifier.new);

class OnboardingGateNotifier extends Notifier<OnboardingGate> {
  Future<void>? _hydration;

  /// Set once onboarding is completed, so a late-resolving hydration read never
  /// clobbers the deliberate transition to [OnboardingGate.done].
  bool _completed = false;

  /// Lets tests await the initial persistence read deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  OnboardingGate build() {
    _hydration = _hydrate();
    return OnboardingGate.unknown;
  }

  Future<void> _hydrate() async {
    try {
      final done = await ref.read(onboardingPreferencesProvider).isPermissionsOnboardingDone();
      if (_completed) return;
      state = done ? OnboardingGate.done : OnboardingGate.pending;
    } catch (_) {
      // Persistence unavailable — fail SAFE to `done` so a prefs hiccup can
      // never trap the user on the onboarding screen or block the app.
      if (!_completed) state = OnboardingGate.done;
    }
  }

  /// Marks the onboarding as completed/skipped and persists the flag so it is
  /// never shown again. Called from the onboarding screen on both "activar" and
  /// "ahora no".
  Future<void> complete() async {
    _completed = true;
    state = OnboardingGate.done;
    try {
      await ref.read(onboardingPreferencesProvider).markPermissionsOnboardingDone();
    } catch (_) {
      // Best-effort persistence; the in-memory state still reflects completion
      // for this session.
    }
  }
}
