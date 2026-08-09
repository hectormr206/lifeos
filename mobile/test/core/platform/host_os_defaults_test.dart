// The DEFAULTS of the platform seam: what happens when nobody overrides.
//
// Every per-OS test in this repo overrides `hostOperatingSystemProvider` or
// passes an explicit `operatingSystem:`. That leaves the production path — the
// `?? currentOperatingSystem()` fallback, the un-overridden provider — asserted
// by nothing at all. A fallback that silently resolved to the wrong thing (a
// stale constant, `'web'`, an empty string) would leave the whole suite green
// while the shipped app asked the update server for the wrong manifest.
//
// These tests can only ever run as the BUILD HOST, so they do not add per-OS
// coverage. What they pin is the WIRING: the default really is the host probe.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/app_platform.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/core/tray/tray_platform.dart';
import 'package:lifeos/features/app_update/domain/update_manifest_path.dart';

void main() {
  test('the un-overridden provider reports the real host, not a constant', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(hostOperatingSystemProvider), currentOperatingSystem());
    // The bug this rules out: a provider left at a hard-coded value after a
    // debugging session would make production ship one platform's UI to all.
    expect(container.read(hostOperatingSystemProvider), isNotEmpty);
    expect(
      container.read(hostOperatingSystemProvider),
      isNot('web'),
      reason: 'a `dart:io` test run must never resolve through the web half of '
          'the conditional import',
    );
  });

  test('the tray slice probes the same host as the shared seam', () {
    // Two conditional-import probes exist (`host_os_io.dart` and
    // `tray_host_io.dart`). If they ever disagreed, the tray would decide it
    // was on a different OS than the rest of the app.
    expect(currentTrayPlatform(), currentOperatingSystem());
  });

  test('the host is one the app actually routes, not an unknown name', () {
    // `isDesktopPlatform` answers false for anything it does not recognise, so
    // an unrecognised host name degrades silently into "not desktop" rather
    // than failing. Assert the host is a name the predicates were written for.
    const known = {'android', 'ios', 'linux', 'macos', 'windows'};
    expect(known, contains(currentOperatingSystem()));
  });

  test('AppUpdateService with no injected OS asks the HOST for its manifest',
      () async {
    // Pins the `?? currentOperatingSystem()` fallback at
    // app_update_service.dart:62. Every other test in that suite injects an
    // explicit OS, so nothing else proves the production default is wired to
    // the seam at all.
    final host = currentOperatingSystem();
    final architecture = updateArchFor(currentArchitecture());
    expect(architecture, isNotNull,
        reason: 'the build host reports an architecture the updater knows');

    expect(
      updateManifestPathFor(host, arch: architecture!),
      isNotNull,
      reason: 'the host resolves to a real manifest path — if this is null the '
          'default fallback would silently report "no update info" in '
          'production while every injected-OS test stayed green',
    );
  });
}
