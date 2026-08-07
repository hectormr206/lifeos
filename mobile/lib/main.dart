import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/background/background_tasks.dart';
import 'core/launch/launch_options.dart';
import 'core/launch/launch_providers.dart';
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

/// [arguments] are the desktop runner's entrypoint arguments (GTK passes them
/// through `fl_dart_project_set_dart_entrypoint_arguments`; Android and web
/// simply hand an empty list). They carry `--hidden` when the login autostart
/// entry started us — see `core/launch/launch_options.dart`.
Future<void> main(List<String> arguments) async {
  final launchOptions = LaunchOptions.parse(arguments);
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
        // Parsed once, here, and injected — so nothing below reaches for the
        // process's real argv, and a widget test can say "we were launched
        // hidden" without one.
        launchOptionsProvider.overrideWithValue(launchOptions),
      ],
      child: const LifeOSApp(),
    ),
  );
}
