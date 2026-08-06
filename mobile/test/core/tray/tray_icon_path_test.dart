import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/tray_icon_path.dart';

/// Where the tray icon file comes from.
///
/// Deliberately NOT a new asset pipeline: `tools/publish-linux-to-vps.sh`
/// already copies `assets/branding/axi-512.png` into the release as
/// `share/lifeos.png`, and `tools/install-linux.sh` already installs that to
/// `/usr/share/icons/hicolor/512x512/apps/lifeos.png` for the .desktop entry
/// (`Icon=lifeos`). The tray reuses exactly those files.
///
/// The wrinkle — verified by reading tray_manager 0.5.3's source, not assumed:
/// `TrayManager.setIcon` does
///
///     path.joinAll([dirname(resolvedExecutable), 'data/flutter_assets', iconPath])
///
/// so a RELATIVE argument is interpreted as a Flutter asset key, while an
/// ABSOLUTE one wins outright (package:path discards earlier parts at an
/// absolute segment). Both forms are therefore legal, and each candidate has
/// to say which one it is: the file we probe for is not always the string we
/// hand to the plugin.
void main() {
  group('trayIconCandidates', () {
    late List<TrayIconCandidate> candidates;

    setUp(() {
      candidates = trayIconCandidates(
        resolvedExecutable: '/opt/lifeos/releases/41/bundle/lifeos',
      );
    });

    test('prefers the installed hicolor icon the .desktop entry already uses', () {
      // Same file as `Icon=lifeos`, so the tray icon and the applications-menu
      // entry are visibly one app.
      expect(candidates.first.probePath,
          '/usr/share/icons/hicolor/512x512/apps/lifeos.png');
      // Absolute, so it is passed straight through to setIcon.
      expect(candidates.first.setIconArgument, candidates.first.probePath);
    });

    test('falls back to the copy shipped inside the release itself', () {
      // Covers a user who unpacked the tarball without running the installer,
      // and survives an `--uninstall` that removed the system icon while a
      // process was still running.
      final release = candidates[1];
      expect(release.probePath, '/opt/lifeos/releases/41/share/lifeos.png');
      expect(release.setIconArgument, release.probePath);
    });

    test('last resort is the bundled Flutter asset, addressed as an asset key', () {
      final asset = candidates.last;
      // Probed as a real file under the bundle…
      expect(
        asset.probePath,
        '/opt/lifeos/releases/41/bundle/data/flutter_assets/assets/branding/axi-512.png',
      );
      // …but handed to setIcon as the RELATIVE asset key, because that is what
      // tray_manager joins onto data/flutter_assets. Passing the probe path
      // here would work too, but the asset key is the documented form and is
      // what keeps working inside a Flatpak/Snap sandbox.
      expect(asset.setIconArgument, 'assets/branding/axi-512.png');
    });

    test('this asset always exists, so `flutter run -d linux` has an icon', () {
      // `assets/branding/` is declared in pubspec.yaml's flutter.assets, so
      // every Linux build — debug included — carries this file. That is why no
      // extra packaging step was needed for the tray.
      expect(candidates.last.setIconArgument, 'assets/branding/axi-512.png');
      expect(candidates, hasLength(3));
    });
  });

  group('resolveTrayIconPath', () {
    TrayIconCandidate candidate(String probe, [String? arg]) =>
        TrayIconCandidate(probePath: probe, setIconArgument: arg ?? probe);

    test('returns the setIcon argument of the first candidate that exists', () {
      final path = resolveTrayIconPath(
        candidates: [
          candidate('/nope/a.png'),
          candidate('/yes/flutter_assets/b.png', 'b.png'),
          candidate('/yes/c.png'),
        ],
        exists: (p) => p.startsWith('/yes/'),
      );
      // The ARGUMENT, not the probe path — those differ for the asset form.
      expect(path, 'b.png');
    });

    test('THROWS when no icon exists instead of installing a blank tray', () {
      // House rule: a feature that cannot start fails loudly. tray_manager
      // accepts a path that is not there and puts an empty, invisible item in
      // the top bar — the user would see nothing and be told nothing. So this
      // raises, the service turns it into a visible notice, and the app runs.
      expect(
        () => resolveTrayIconPath(
          candidates: [candidate('/nope/a.png')],
          exists: (_) => false,
        ),
        throwsA(
          isA<TrayUnavailableException>().having(
            (e) => e.message,
            'message',
            allOf(contains('icon'), contains('/nope/a.png')),
          ),
        ),
      );
    });
  });

  group('TrayUnavailableException.noHost', () {
    test('names the two things the user can actually check', () {
      // This is the message that reaches the in-app notice when the plugin
      // itself rejects the icon. A bare PlatformException would tell the user
      // nothing; these are the only two causes he can do anything about.
      final message = TrayUnavailableException.noHost(
        'PlatformException(setIcon)',
      ).message;

      expect(message, contains('PlatformException(setIcon)'));
      expect(message, contains('Wayland'));
      expect(message, contains('libayatana-appindicator3'));
      // And it must say the app is still fine, for the same reason the
      // Spanish notice does.
      expect(message, contains('keeps running'));
    });
  });

  group('trayTooltipIsSupportedOn', () {
    test('is false on Linux — the plugin answers not-implemented there', () {
      // Verified against tray_manager 0.5.3's linux/tray_manager_plugin.cc:
      // it handles destroy/setIcon/setTitle/setContextMenu and replies
      // `fl_method_not_implemented_response_new()` to everything else, which
      // surfaces in Dart as a MissingPluginException. Calling setToolTip on
      // Linux would therefore make a PERFECTLY WORKING tray report itself as
      // unavailable — the loud-failure rule cuts both ways.
      expect(trayTooltipIsSupportedOn('linux'), isFalse);
    });

    test('is true on macOS and Windows, where the plugin implements it', () {
      expect(trayTooltipIsSupportedOn('macos'), isTrue);
      expect(trayTooltipIsSupportedOn('windows'), isTrue);
    });
  });
}
