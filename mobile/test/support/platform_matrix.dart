// Run a test once per supported operating system, deliberately.
//
// ─────────────────────────────────────────────────────────────────────────────
// READ THIS BEFORE YOU TRUST A GREEN RUN
//
// A green platform matrix means: THE DART BRANCHES ARE EXERCISED.
// It does NOT mean: THE APP STARTS ON THAT PLATFORM.
//
// `flutter test` runs on the Dart VM of the build machine with NO PLUGINS
// REGISTERED. Every platform channel — permission_handler, record,
// flutter_local_notifications, workmanager, tray_manager, path_provider,
// flutter_secure_storage — returns null or throws `MissingPluginException`.
// So the entire class of "the app crashes on the phone because a plugin call
// at startup failed" is invisible here, on every OS in this matrix, forever.
//
// That is not a hypothetical. Two builds that were green on this suite reached
// the user's real Pixel broken. This helper does not fix that and cannot.
// Device coverage comes from running the app on the dedicated Pixel over adb.
//
// What this helper DOES buy: the OS-name branches in `lib/` (desktop-only
// widgets, mobile-only rows, per-OS providers) stop being decided silently by
// whatever machine the CI happens to be, which until now was always `linux`.
// A desktop-only widget constructed on the mobile path, a provider that
// returns null on Android and is then dereferenced, a Settings row that
// vanishes on the wrong platform — those it catches.
//
// If you ever find yourself saying "the matrix is green so Android is fine",
// this file made things worse, not better. It is green because the Dart said
// the same thing twice, not because anything ran on a phone.
// ─────────────────────────────────────────────────────────────────────────────
//
// Why a matrix at all: `hostOperatingSystemProvider` defaults to
// `Platform.operatingSystem`, which under `flutter test` is the build host —
// always `'linux'`. Of 311 test files, 17 overrode it. The other 294 asserted
// the desktop shape while believing they asserted "the app".
import 'package:flutter_test/flutter_test.dart';

/// Re-exported so ONE import gives a test both the matrix and the provider it
/// overrides. Riverpod 3 does not export the `Override` type publicly, so a
/// `hostOperatingSystemOverride(os)` helper cannot be written with a real
/// return type — `hostOperatingSystemProvider.overrideWithValue(os)` written
/// inline is the shape the language supports, and it is already what all 17
/// pre-existing platform tests do.
export 'package:lifeos/core/platform/platform_providers.dart'
    show hostOperatingSystemProvider;

/// The operating systems every platform-dependent test runs against.
///
/// Two, not five, and on purpose: `android` is the shape on the user's real
/// phone, `linux` is the shape on his desktop. `macos` and `windows` share
/// every predicate branch with `linux` (see `isDesktopPlatform`) and this repo
/// ships no runner for them, so adding them would triple the runtime to assert
/// the same branch three times. `ios` and `web` likewise fold into an existing
/// branch. Pass [operatingSystems] explicitly where a test genuinely needs one
/// of those — for example asserting that an UNKNOWN OS name is handled.
const List<String> supportedOperatingSystems = <String>['android', 'linux'];

/// Runs [body] once per operating system in the matrix, as its own group.
///
/// The one-liner this exists for:
///
/// ```dart
/// testPerOperatingSystem('the Dictar button', (os) {
///   testWidgets('renders', (tester) async {
///     await tester.pumpWidget(ProviderScope(
///       overrides: [hostOperatingSystemProvider.overrideWithValue(os)],
///       child: const LifeOSApp(),
///     ));
///     expect(find.text('Dictar'), findsOneWidget);
///   });
/// });
/// ```
///
/// [body] receives the OS name so it can both build the override AND branch
/// its own expectations — most platform tests assert DIFFERENT things per OS
/// (a row is present here, absent there), so a helper that only ran the same
/// assertions twice would be useless for exactly the cases that matter.
///
/// See the file header for what a green run does and does not prove.
void testPerOperatingSystem(
  String description,
  void Function(String operatingSystem) body, {
  List<String> operatingSystems = supportedOperatingSystems,
}) {
  for (final operatingSystem in operatingSystems) {
    group('$description [$operatingSystem]', () => body(operatingSystem));
  }
}
