// WHERE THE APP LEARNS WHICH BUILD IS INSTALLED — and why that differs per OS.
//
// THE DEFECT THIS PINS. On Linux the app reported build 1 forever. Release 795
// was installed and the Updates screen still said "Versión instalada 0.9.19
// (1)" and still offered "Actualizar ahora" for a release the user had already
// installed — immediately after a successful update. Measured on the user's
// laptop, and reproduced from the installed bundle itself:
//
//   $ cat /opt/lifeos/current/bundle/data/flutter_assets/version.json
//   {"app_name":"lifeos","version":"0.9.19","build_number":"1", …}
//
// `tools/publish-linux-to-vps.sh` DOES pass `--build-number`, and the Linux
// build drops it on the floor. Traced through Flutter 3.44.8: `flutter build
// linux` hands CMake only `BuildInfo.toEnvironmentConfig()`, which lists
// DART_DEFINES, obfuscation, tree-shaking and friends but NOT BuildName or
// BuildNumber (`build_info.dart`); CMake then calls
// `flutter_tools/bin/tool_backend.dart`, whose `flutter assemble` argument list
// has no `-dBuildNumber` either. So `BundleLinuxAssets.getVersionInfo(defines)`
// — which WOULD honour `kBuildNumber` if it ever arrived — falls back to
// pubspec's `+1` and writes it into version.json, which is exactly what
// `package_info_plus` reads back. On desktop `1 < 795` is therefore true
// forever and the nag never stops.
//
// THE RULE THIS ENCODES. Behaviour stays shared — one comparison, one screen,
// one banner. Only the SOURCE of "which build am I" is per platform: the
// installer's own manifest on desktop, `package_info_plus` on Android. These
// tests run the SAME screen against the SAME server manifest on both, and
// assert the two outcomes that follow.
//
// See test/support/platform_matrix.dart for what a green run here does and
// does not prove.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/data/app_update_service.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';
import 'package:lifeos/features/app_update/domain/update_source_config.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_updates_screen.dart';
import 'package:lifeos/features/app_update/presentation/update_available_banner.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../../support/platform_matrix.dart';
import '../support/fakes.dart';

/// The release the user really has installed, as `install-linux.sh` recorded it
/// in `/opt/lifeos/manifest.json`.
const _installed = InstalledRelease(versionCode: 795, versionName: '0.9.19');

/// What `package_info_plus` says on that same machine: pubspec's `+1`.
const _packageBuildNumber = 1;

const _config = UpdateSourceConfig(
  baseUrl: 'https://updates.example/lifeos',
  accessKey: 'test-key-123',
);

/// The server publishes exactly what is installed — 795. Nothing to update to.
String _serverManifest(int versionCode) => jsonEncode({
      'versionCode': versionCode,
      'versionName': '0.9.19',
      'apkFilename': 'lifeos-0.9.19-$versionCode.apk',
      'sha256': 'abc',
      'sizeBytes': 57642149,
      'notes': 'Correcciones',
      'publishedAt': '2026-08-05T00:00:00+00:00',
    });

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.body);
  final String body;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}

/// Everything faked is a PLATFORM EDGE and nothing else: the disk under
/// `/opt/lifeos`, `package_info_plus`, the HTTP transport, preferences and
/// notifications. The version source, the comparison and the widgets are the
/// real ones — which is the only way this proves anything about the defect.
///
/// Returns the whole scoped widget rather than a bare override list because
/// Riverpod 3 does not export `Override` publicly, so a `List<Override>` helper
/// cannot be written with a real return type — the same constraint that stops
/// test/support/platform_matrix.dart from offering an override helper.
Widget _scoped(
  String os, {
  required InstalledRelease? onDisk,
  required int serverVersionCode,
  required Widget home,
}) =>
    ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue(os),
        installedReleaseReaderProvider
            .overrideWithValue(FakeInstalledReleaseReader(onDisk)),
        packageAppVersionInfoProvider.overrideWithValue(
            FakeAppVersionInfo(code: _packageBuildNumber, name: '0.9.19')),
        appUpdateServiceProvider.overrideWith((ref) => AppUpdateService(
              Dio(BaseOptions(baseUrl: _config.baseUrl))
                ..httpClientAdapter =
                    _FixedResponseAdapter(_serverManifest(serverVersionCode)),
              ref.watch(appVersionInfoProvider),
              config: _config,
              operatingSystem: os,
              architecture: 'x64',
            )),
        appUpdatePreferencesProvider
            .overrideWithValue(FakeAppUpdatePreferences()),
        updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

/// Pumps the real Home reminder and runs one real update check through it.
Future<void> _pumpBanner(WidgetTester tester, String os) async {
  await tester.pumpWidget(_scoped(
    os,
    onDisk: _installed,
    serverVersionCode: 795,
    home: const Scaffold(body: UpdateAvailableBanner()),
  ));
  await tester.pumpAndSettle();
  final container =
      ProviderScope.containerOf(tester.element(find.byType(UpdateAvailableBanner)));
  // Started, NOT awaited from the test body: the check crosses real async gaps
  // and only the tester's clock drives those. Awaiting here deadlocks.
  unawaited(container.read(appUpdateNotifierProvider.notifier).check());
  await tester.pumpAndSettle();
}

/// Pumps the real screen with the real comparison, the real per-platform
/// version source, and a scripted server.
Future<void> _pump(
  WidgetTester tester,
  String os, {
  required InstalledRelease? onDisk,
  int serverVersionCode = 795,
}) async {
  await tester.pumpWidget(_scoped(
    os,
    onDisk: onDisk,
    serverVersionCode: serverVersionCode,
    home: const AppUpdatesScreen(),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Buscar actualizaciones'));
  await tester.pumpAndSettle();
}

void main() {
  testPerOperatingSystem('the installed build number', (os) {
    testWidgets('comes from the installer manifest on desktop, package metadata on Android',
        (tester) async {
      await _pump(tester, os, onDisk: _installed);

      if (os == 'linux') {
        // The whole point: 795 off the manifest, NOT the 1 that
        // package_info_plus reads out of the bundle's version.json.
        expect(find.textContaining('0.9.19 (795)'), findsOneWidget);
        expect(find.textContaining('(1)'), findsNothing);
      } else {
        // Android's versionCode comes through correctly and must keep doing so.
        expect(find.textContaining('0.9.19 (1)'), findsOneWidget);
      }
    });

    testWidgets('decides whether an update is pending, against the same server manifest',
        (tester) async {
      await _pump(tester, os, onDisk: _installed);

      if (os == 'linux') {
        // 795 published, 795 installed. The user updated successfully; the app
        // must stop telling him he is out of date.
        expect(find.text('Actualizar ahora'), findsNothing);
        expect(find.textContaining('Ya tienes la última versión'), findsOneWidget);
      } else {
        // Android really is on build 1, so 795 really is an update.
        expect(find.text('Actualizar ahora'), findsOneWidget);
      }
    });
  });

  testWidgets('desktop with a newer build published still offers the update', (tester) async {
    // The guard against over-correcting: reading the manifest must not make the
    // app blind to real updates.
    await _pump(tester, 'linux', onDisk: _installed, serverVersionCode: 800);

    expect(find.text('Actualizar ahora'), findsOneWidget);
  });

  testWidgets('desktop with no readable manifest says so and offers nothing', (tester) async {
    // A dev `flutter run`, or an install older than the manifest. Falling back
    // to package_info_plus here would reinstate the exact false "actualización
    // disponible" this whole file exists to kill, so the app says it does not
    // know instead of comparing against a number it cannot trust.
    await _pump(tester, 'linux', onDisk: null);

    expect(find.textContaining('No se pudo determinar la versión instalada'),
        findsWidgets);
    expect(find.text('Actualizar ahora'), findsNothing);
    expect(find.textContaining('(1)'), findsNothing);
  });

  testPerOperatingSystem('the Home reminder', (os) {
    testWidgets('stops nagging once the installed build matches the published one',
        (tester) async {
      // The screen was only half of it: the banner reads the SAME status, so a
      // wrong installed build made Home nag on every launch too. Pumped through
      // the real notifier so this is the shared status, not a second opinion.
      await _pumpBanner(tester, os);

      if (os == 'linux') {
        expect(find.text('Nueva versión disponible'), findsNothing);
      } else {
        expect(find.text('Nueva versión disponible'), findsOneWidget);
      }
    });
  });

  testWidgets('desktop with only the release symlink shows the build alone', (tester) async {
    // The symlink fallback recovers 795 but carries no version name, and
    // inventing one would put a string in front of the user that matches no
    // release note. The build number alone is the honest answer.
    await _pump(
      tester,
      'linux',
      onDisk: const InstalledRelease(versionCode: 795, versionName: ''),
    );

    expect(find.textContaining('795'), findsWidgets);
    expect(find.text('Actualizar ahora'), findsNothing);
  });
}
