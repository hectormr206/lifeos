import 'dart:io';

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
/// through `fl_dart_project_set_dart_entrypoint_arguments`). They carry
/// `--hidden` when the login autostart entry started us — see
/// `core/launch/launch_options.dart`.
///
/// THE PARAMETER IS OPTIONAL, AND THAT IS NOT STYLE. Android's embedder does
/// NOT hand the entrypoint an empty list — `FlutterFragmentActivity`'s
/// `getDartEntrypointArgs()` reads an intent extra that a normal launcher
/// start never sets, so it returns null and `main` is invoked with NO
/// arguments. A required positional parameter therefore fails to invoke and
/// the app dies the instant it opens, on the phone only, while every desktop
/// build and the entire test suite stay green. It shipped exactly that way.
Future<void> main([List<String> arguments = const []]) async {
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
  // Un temporizador nos pidió el boletín y nada más. Hacemos ese trabajo y
  // salimos: sin ventana, sin icono en la bandeja y sin bloqueo por
  // biometría, que aquí no tendría a quién preguntarle.
  //
  // Es lo que le faltaba al escritorio. `workmanager` sólo existe en Android e
  // iOS, así que en la laptop el boletín únicamente se generaba si alguien
  // abría la aplicación — justo lo que un boletín de la mañana no puede
  // depender. El generador ya corría headless; sólo faltaba quién se lo
  // pidiera desde fuera.
  if (launchOptions.runBriefingAndExit) {
    final ok = await runBriefingJobAndExit();
    exit(ok ? 0 : 1);
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

/// El trabajo que hace `--run-briefing`: generar el boletín y decir si salió.
///
/// Devuelve `false` en vez de tragarse el fallo, porque quien lo llama es
/// systemd: un servicio que siempre termina en 0 es un servicio del que nadie
/// se entera cuando lleva un mes sin generar nada.
Future<bool> runBriefingJobAndExit() async {
  try {
    return await executeMorningBriefingBackgroundTask();
  } catch (error, stack) {
    stderr.writeln('lifeos --run-briefing falló: $error');
    stderr.writeln(stack);
    return false;
  }
}
