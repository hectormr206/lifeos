import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/background/background_tasks.dart';
import 'features/security/domain/app_lock_preferences.dart';
import 'features/security/presentation/app_lock_providers.dart';

/// Resolves the pre-frame app-lock flag with a FAIL-SAFE error policy:
///  * a successful read is authoritative — a MISSING key reads as `false`
///    ("lock was never enabled", the documented contract), so a fresh install
///    starts open;
///  * a read ERROR (prefs channel/store failure) means the lock MIGHT be armed
///    and we cannot know — default to LOCKED rather than reveal content. A
///    user who never enabled the lock is not bricked: the lock screen's
///    `unavailable` path offers "Desactivar bloqueo" as the escape hatch.
Future<bool> resolveInitialAppLockEnabled(AppLockPreferences prefs) async {
  try {
    return await prefs.isEnabled();
  } catch (_) {
    return true; // fail CLOSED on error only.
  }
}

Future<void> main() async {
  // Resolve the optional biometric app-lock flag BEFORE the first frame so the
  // gate knows synchronously whether to lock — no splash, and a lock-enabled
  // user never flashes their on-device data on cold start. Defaults to OFF on
  // a successful "off" read; a FAILED read fails SAFE (locked) — see
  // [resolveInitialAppLockEnabled].
  WidgetsFlutterBinding.ensureInitialized();
  // Background work ("Boletín automático" en segundo plano): register the
  // WorkManager callback dispatcher so one-off tasks can run headless with the
  // app closed. Must happen before any registerOneOffTask; best-effort so a
  // platform without the plugin (host tests, desktop) never blocks startup.
  try {
    await Workmanager().initialize(backgroundTaskDispatcher);
  } catch (_) {
    // No WorkManager here — the reminder + generate-on-open fallback remains.
  }
  final appLockEnabled =
      await resolveInitialAppLockEnabled(SharedPrefsAppLockPreferences());
  runApp(
    ProviderScope(
      overrides: [
        appLockInitialEnabledProvider.overrideWithValue(appLockEnabled),
      ],
      child: const LifeOSApp(),
    ),
  );
}
