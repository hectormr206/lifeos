import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/autostart/domain/login_autostart.dart';
import 'package:lifeos/features/autostart/domain/stable_executable.dart';

/// Which command the login entry should run.
///
/// `Platform.resolvedExecutable` is NOT the answer: it resolves symlinks, so
/// on a real install it reports
/// `/opt/lifeos/releases/{versionCode}/bundle/lifeos` — precisely the
/// versioned path that the next update prunes. The
/// stable path has to be recovered by resolving each known stable entry point
/// and checking which one leads back to the binary we are.
void main() {
  const running = '/opt/lifeos/releases/10420/bundle/lifeos';

  group('resolveStableExecutablePath', () {
    test('prefers the `current` symlink the installer maintains', () {
      final path = resolveStableExecutablePath(
        runningExecutable: running,
        candidates: linuxStableExecutableCandidates,
        resolveRealPath: (candidate) => switch (candidate) {
          '/opt/lifeos/current/bundle/lifeos' => running,
          '/usr/local/bin/lifeos' => running,
          _ => null,
        },
      );
      expect(path, '/opt/lifeos/current/bundle/lifeos');
    });

    test('falls back to the /usr/local/bin launcher', () {
      final path = resolveStableExecutablePath(
        runningExecutable: running,
        candidates: linuxStableExecutableCandidates,
        resolveRealPath: (candidate) =>
            candidate == '/usr/local/bin/lifeos' ? running : null,
      );
      expect(path, '/usr/local/bin/lifeos');
    });

    test('ignores a stable path that points at a DIFFERENT install', () {
      // Two installs on one machine, or a leftover symlink from an uninstall.
      // Registering someone else's binary to start at login would be worse
      // than not registering at all.
      expect(
        () => resolveStableExecutablePath(
          runningExecutable: running,
          candidates: linuxStableExecutableCandidates,
          resolveRealPath: (_) => '/opt/other/bundle/lifeos',
        ),
        throwsA(isA<LoginAutostartUnavailableException>()),
      );
    });

    test('a dev build FAILS LOUDLY instead of registering a build directory',
        () {
      // Under `flutter run` the binary lives in `build/linux/.../bundle/`,
      // which is deleted by `flutter clean` and never exists on the user's
      // machine. Writing it into ~/.config/autostart would leave a login entry
      // for a path that vanishes — a silent breakage, so it is refused.
      Object? thrown;
      try {
        resolveStableExecutablePath(
          runningExecutable:
              '/home/h/dev/lifeos/mobile/build/linux/x64/debug/bundle/lifeos',
          candidates: linuxStableExecutableCandidates,
          resolveRealPath: (_) => null,
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<LoginAutostartUnavailableException>());
      expect(
        (thrown! as LoginAutostartUnavailableException).message,
        contains('installed'),
      );
    });

    test('the message names the candidates it looked at', () {
      // The user (or whoever reads the log) must be able to act on it.
      try {
        resolveStableExecutablePath(
          runningExecutable: running,
          candidates: linuxStableExecutableCandidates,
          resolveRealPath: (_) => null,
        );
        fail('expected a loud failure');
      } on LoginAutostartUnavailableException catch (e) {
        for (final candidate in linuxStableExecutableCandidates) {
          expect(e.message, contains(candidate));
        }
      }
    });

    test('whatever it returns is never a versioned path', () {
      for (final candidate in linuxStableExecutableCandidates) {
        expect(candidate, isNot(contains('releases')));
      }
    });
  });

  test('the candidate list matches tools/install-linux.sh', () {
    // `$CURRENT_LINK/bundle/lifeos` is exactly what install_desktop_entry
    // writes into Exec=, and `$LAUNCHER_LINK` is /usr/local/bin/lifeos.
    expect(linuxStableExecutableCandidates, const [
      '/opt/lifeos/current/bundle/lifeos',
      '/usr/local/bin/lifeos',
    ]);
  });
}
