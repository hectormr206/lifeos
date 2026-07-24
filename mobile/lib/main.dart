import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'features/security/domain/app_lock_preferences.dart';
import 'features/security/presentation/app_lock_providers.dart';

Future<void> main() async {
  // Resolve the optional biometric app-lock flag BEFORE the first frame so the
  // gate knows synchronously whether to lock — no splash, and a lock-enabled
  // user never flashes their on-device data on cold start. Defaults to OFF; a
  // failed read must fail SAFE (locked) rather than reveal content, so it only
  // falls back to `false` when persistence genuinely reports the lock is off.
  WidgetsFlutterBinding.ensureInitialized();
  bool appLockEnabled = false;
  try {
    appLockEnabled = await SharedPrefsAppLockPreferences().isEnabled();
  } catch (_) {
    // Persistence unavailable: leave the lock off (it can only have been armed
    // via a successful in-app enable, which also wrote the pref).
    appLockEnabled = false;
  }
  runApp(
    ProviderScope(
      overrides: [
        appLockInitialEnabledProvider.overrideWithValue(appLockEnabled),
      ],
      child: const LifeOSApp(),
    ),
  );
}
