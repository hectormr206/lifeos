// The banner that says a newer build is already installed.
//
// See domain/restart_pending.dart for what happened and why this exists: the
// update had been on disk for six hours and the app had no way to say so, so
// the user reasonably concluded it had never arrived.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/restart_pending.dart';
import '../presentation/app_update_providers.dart';

/// Where the desktop installer leaves what it installed.
const String kInstalledManifestPath = '/opt/lifeos/manifest.json';

/// Reads the installed build, or null when there is nothing to read.
///
/// Null on Android and on a dev run, which is exactly right: an APK install
/// restarts the app, so the situation this warns about cannot happen there.
final installedBuildProvider = FutureProvider<({int? code, String name})?>(
  (ref) async {
    try {
      final file = File(kInstalledManifestPath);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final code = installedVersionFrom(text);
      if (code == null) return null;
      // The NAME is what the user is told, so it comes from the same file
      // rather than being reconstructed.
      final name = RegExp(r'"versionName"\s*:\s*"([^"]+)"').firstMatch(text);
      return (code: code, name: name?.group(1) ?? '$code');
    } catch (_) {
      return null;
    }
  },
);

/// The build currently RUNNING, from the package metadata.
final runningBuildProvider = FutureProvider<int?>(
  (ref) => ref.watch(appVersionInfoProvider).buildNumber(),
);

class RestartPendingBanner extends ConsumerWidget {
  const RestartPendingBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedBuildProvider).value;
    if (installed == null) return const SizedBox.shrink();

    final running = ref.watch(runningBuildProvider).value;
    if (!needsRestart(running: running, installed: installed.code)) {
      return const SizedBox.shrink();
    }

    return MaterialBanner(
      content: Text(restartMessage(installedName: installed.name)),
      leading: const Icon(Icons.restart_alt),
      actions: const [SizedBox.shrink()],
    );
  }
}
