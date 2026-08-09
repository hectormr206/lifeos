// Nothing in `lib/` may ask `dart:io` what OS it is, except the seam itself.
//
// This is a source contract rather than a behavioural test because the defect
// it guards is INVISIBLE at runtime under `flutter test`: a widget that reads
// `Platform.isAndroid` inline still compiles, still runs, and still passes —
// it just silently answers "linux" on the build host, on every one of the 2100+
// tests, forever. The test suite cannot tell you it is only ever testing the
// desktop shape. Only the source can.
//
// The rule: an OS decision must take the operating-system NAME as a parameter
// (`isDesktopPlatform(os)`) or come from `hostOperatingSystemProvider`, both of
// which a test can override. A direct `Platform.isAndroid` is untestable BY
// CONSTRUCTION — there is no seam to push on — so it is banned at the source
// level rather than caught later by a test that will never be written.
//
// The allowlist below is not an exemption from the rule; it IS the seam. Each
// entry is a thin default binding whose only job is to feed the real host OS
// into a pure, OS-name-parameterised function that tests exercise directly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The banned reads: every `Platform` member that answers "which OS is this".
///
/// Deliberately NOT anchored on `dart:io`'s import, because `Platform` is also
/// re-exported by `package:universal_io` and friends — matching the member
/// access catches the read however the type arrived.
final RegExp _hostOsRead = RegExp(
  r'\bPlatform\s*\.\s*(operatingSystem|operatingSystemVersion|'
  r'isAndroid|isIOS|isLinux|isMacOS|isWindows|isFuchsia)\b',
);

/// Files permitted to read the host OS directly, each with the reason.
///
/// Adding an entry here is a real decision, not a formality: it means the file
/// contains a branch no test on any machine can flip. Keep them at zero logic —
/// resolve the OS name and hand it straight to a parameterised function.
const Map<String, String> _allowedDirectReads = <String, String>{
  // THE SEAM. `currentOperatingSystem()` is the one place the real OS enters
  // the app; `hostOperatingSystemProvider` wraps it and tests override that.
  'lib/core/platform/host_os_io.dart':
      'the IO half of the host-OS probe — this IS the seam',
  // The tray slice has its own conditional-import probe of the same shape,
  // predating the shared one. Same contract: name in, pure predicate decides.
  'lib/core/tray/tray_host_io.dart':
      'the IO half of the tray host-OS probe — same seam, tray slice',
  // Default argument only. Every test constructs it with an explicit
  // `operatingSystem:`, and the file is unreachable off desktop anyway
  // (`TrayService` calls it only after `trayIsSupportedOn` says yes).
  'lib/core/tray/tray_manager_hosts.dart':
      'default for an injectable `operatingSystem` constructor parameter',
  // Default binding only: `graphDatabaseBackendFor(os)` is pure and is tested
  // for every OS name including the throwing unknown-platform case.
  'lib/core/graph/graph_database_backend.dart':
      'default binding feeding the pure `graphDatabaseBackendFor(os)`',
  // Runs inside the WorkManager background isolate, which has no widget tree
  // and therefore no ProviderContainer to override. `VpnGate` takes the OS
  // name as a parameter and is tested for both branches through it.
  'lib/core/background/background_tasks.dart':
      'background isolate has no ProviderContainer; feeds `VpnGate(operatingSystem:)`',
};

List<File> _dartSourcesUnder(String directory) =>
    Directory(directory)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// Strips `//` line comments so a doc comment that NAMES `Platform.isAndroid`
/// while explaining why it is not used does not read as a violation. Several
/// files in this repo do exactly that.
String _withoutLineComments(String source) => source
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment == -1 ? line : line.substring(0, comment);
    })
    .join('\n');

void main() {
  test('no file outside the platform seam reads the host OS directly', () {
    final violations = <String>[];

    for (final file in _dartSourcesUnder('lib')) {
      if (_allowedDirectReads.containsKey(file.path)) continue;
      final source = _withoutLineComments(file.readAsStringSync());
      for (final match in _hostOsRead.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('${file.path}:$line  ${match.group(0)}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'These read the host OS directly, so under `flutter test` they '
          'always answer with the BUILD MACHINE (linux) and their Android '
          'branch can never be exercised:\n  ${violations.join('\n  ')}\n\n'
          'Route the decision through `hostOperatingSystemProvider` (a widget '
          'or provider) or take the OS name as a parameter and use the pure '
          'predicates in lib/core/platform/app_platform.dart. If the code '
          'genuinely cannot reach a ProviderContainer, add it to '
          '_allowedDirectReads WITH a reason.',
    );
  });

  test('the allowlist has not gone stale', () {
    // An allowlist entry whose file was deleted or already cleaned up is a
    // standing permission nobody is watching. Removing it is free; leaving it
    // means a future direct read in that path passes unnoticed.
    for (final entry in _allowedDirectReads.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue,
          reason: '${entry.key} is allowlisted but does not exist — '
              'delete the entry');
      expect(
        _hostOsRead.hasMatch(_withoutLineComments(file.readAsStringSync())),
        isTrue,
        reason: '${entry.key} no longer reads the host OS directly, so its '
            'allowlist entry ("${entry.value}") is stale — delete it, or the '
            'next direct read there goes unnoticed',
      );
    }
  });

  group('POSITIVE CONTROL — the contract can still fail', () {
    // A source contract that silently stops matching reports a clean codebase
    // forever, which is precisely how the defect it guards survived a green
    // suite in the first place. These prove the pattern still bites.
    test('the pattern catches every banned read', () {
      const offenders = <String>[
        'if (Platform.isAndroid) return const AndroidThing();',
        'final os = Platform.operatingSystem;',
        'Platform . isLinux', // whitespace around the dot
        'return Platform.isIOS || Platform.isMacOS;',
        'if (Platform.isWindows) {}',
        'if (Platform.isFuchsia) {}',
        'log(Platform.operatingSystemVersion);',
      ];
      for (final offender in offenders) {
        expect(_hostOsRead.hasMatch(offender), isTrue,
            reason: 'the contract would NOT have caught: $offender');
      }
    });

    test('the pattern does not fire on things that only look like it', () {
      const innocents = <String>[
        'final platform = Theme.of(context).platform;',
        'if (defaultTargetPlatform == TargetPlatform.android) {}',
        'class PlatformIsAndroidHelper {}',
        'supportsDictation(operatingSystem)',
        'Platform.pathSeparator', // a real, permitted dart:io read
        'Platform.environment',
        'Platform.isAndroidish', // \b guards against a prefix match
      ];
      for (final innocent in innocents) {
        expect(_hostOsRead.hasMatch(innocent), isFalse,
            reason: 'the contract falsely flags: $innocent');
      }
    });

    test('a violating file in lib/ is actually reported', () {
      // The scan itself, not just the regex: proves the walk reaches lib/,
      // reads files, and turns a hit into a violation line. Uses a real file
      // written into lib/ and removed again, because a scan that silently
      // walked an empty list would pass every other test in this file.
      final planted = File('lib/__platform_seam_contract_probe.dart');
      addTearDown(() {
        if (planted.existsSync()) planted.deleteSync();
      });
      planted.writeAsStringSync(
          'import "dart:io";\nbool probe() => Platform.isAndroid;\n');

      final violations = <String>[];
      for (final file in _dartSourcesUnder('lib')) {
        if (_allowedDirectReads.containsKey(file.path)) continue;
        if (_hostOsRead.hasMatch(_withoutLineComments(file.readAsStringSync()))) {
          violations.add(file.path);
        }
      }

      expect(violations, contains(planted.path),
          reason: 'the scan did not report a file that plainly violates it — '
              'the contract is reporting clean because it is not looking');
    });

    test('a comment mentioning the banned read is not a violation', () {
      const documented = '// Never write `Platform.isAndroid` here — use the seam.';
      expect(_hostOsRead.hasMatch(_withoutLineComments(documented)), isFalse);
    });
  });
}
