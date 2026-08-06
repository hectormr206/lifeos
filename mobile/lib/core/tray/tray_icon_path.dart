import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';

import 'tray_controller.dart';

export 'tray_controller.dart' show TrayUnavailableException;

/// One place the tray icon might come from.
///
/// [probePath] and [setIconArgument] are separate because tray_manager 0.5.3's
/// `setIcon` does
///
///     path.joinAll([dirname(resolvedExecutable), 'data/flutter_assets', iconPath])
///
/// which means a RELATIVE argument is read as a Flutter asset key while an
/// ABSOLUTE one wins outright (package:path discards everything before an
/// absolute segment). So the file we check for on disk is not always the
/// string the plugin wants — conflating them would silently install an icon
/// that renders nothing.
@immutable
class TrayIconCandidate {
  const TrayIconCandidate({
    required this.probePath,
    required this.setIconArgument,
  });

  /// The real file to test for existence.
  final String probePath;

  /// What to hand to `TrayManager.setIcon`.
  final String setIconArgument;

  @override
  String toString() => probePath;
}

/// Where the tray icon comes from — reusing what packaging ALREADY ships, with
/// no new asset pipeline.
///
/// The chain that already exists:
///   * `assets/branding/axi-512.png` lives in the repo and is declared in
///     `pubspec.yaml`'s `flutter.assets`, so EVERY build bundles it;
///   * `tools/publish-linux-to-vps.sh` copies it into the release tarball as
///     `share/lifeos.png` (next to `bundle/lifeos`);
///   * `tools/install-linux.sh` installs that to
///     `/usr/share/icons/hicolor/512x512/apps/lifeos.png` and writes a
///     `.desktop` entry pointing at it with `Icon=lifeos`.
///
/// [resolvedExecutable] is `Platform.resolvedExecutable`, i.e.
/// `<release>/bundle/lifeos`. Taking it as a parameter (rather than reading
/// `Platform` inline) is what makes the candidate list assertable on a host
/// with no LifeOS installed.
List<TrayIconCandidate> trayIconCandidates({
  required String resolvedExecutable,
}) {
  final bundleDir = _dirname(resolvedExecutable); // <release>/bundle
  final releaseDir = _dirname(bundleDir); // <release>

  const asset = 'assets/branding/axi-512.png';

  return <TrayIconCandidate>[
    // 1. The installed system icon — the one `Icon=lifeos` already resolves
    //    to, so the tray and the applications menu are visibly the same app.
    const TrayIconCandidate(
      probePath: '/usr/share/icons/hicolor/512x512/apps/lifeos.png',
      setIconArgument: '/usr/share/icons/hicolor/512x512/apps/lifeos.png',
    ),
    // 2. The copy inside the release. Covers an unpacked-but-not-installed
    //    tarball, and survives an `--uninstall` that removed the system icon
    //    while a process was still running.
    TrayIconCandidate(
      probePath: '$releaseDir/share/lifeos.png',
      setIconArgument: '$releaseDir/share/lifeos.png',
    ),
    // 3. The bundled Flutter asset. Always present (it is in flutter.assets),
    //    which is what makes `flutter run -d linux` from a checkout work
    //    without installing anything. Addressed by ASSET KEY, the documented
    //    form, which also keeps working inside a Flatpak/Snap sandbox where
    //    host paths do not match what the app sees.
    TrayIconCandidate(
      probePath: '$bundleDir/data/flutter_assets/$asset',
      setIconArgument: asset,
    ),
  ];
}

/// Picks the first candidate that exists and returns what to pass to
/// `setIcon`, or raises.
///
/// HOUSE RULE: no silent degradation. tray_manager will happily accept a path
/// that is not there and put an empty, invisible item in the top bar — the
/// user sees nothing and is told nothing, which is precisely the quiet failure
/// this codebase forbids. So a missing icon throws, the service turns it into
/// a visible "tray unavailable" notice, and the app runs on without one.
String resolveTrayIconPath({
  required List<TrayIconCandidate> candidates,
  bool Function(String path)? exists,
}) {
  final probe = exists ?? (path) => File(path).existsSync();
  for (final candidate in candidates) {
    if (probe(candidate.probePath)) return candidate.setIconArgument;
  }
  throw TrayUnavailableException.noIcon(
    candidates.map((c) => c.probePath).toList(),
  );
}

/// The setIcon argument for the running process.
String resolveTrayIconPathForHost() => resolveTrayIconPath(
      candidates: trayIconCandidates(
        resolvedExecutable: Platform.resolvedExecutable,
      ),
    );

/// Whether `TrayManager.setToolTip` does anything on [operatingSystem].
///
/// Verified against tray_manager 0.5.3's `linux/tray_manager_plugin.cc`: it
/// handles `destroy`, `setIcon`, `setTitle` and `setContextMenu`, and replies
/// `fl_method_not_implemented_response_new()` to everything else — which
/// reaches Dart as a `MissingPluginException`.
///
/// This matters because of the loud-failure rule, which cuts both ways: a
/// blanket `setToolTip` call would make a perfectly working Linux tray report
/// itself as unavailable, and an app that cries wolf is one whose warnings the
/// user learns to ignore.
bool trayTooltipIsSupportedOn(String operatingSystem) =>
    operatingSystem == 'macos' || operatingSystem == 'windows';

String _dirname(String path) {
  final index = path.lastIndexOf('/');
  if (index <= 0) return index == 0 ? '/' : '.';
  return path.substring(0, index);
}
