import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// MOBILE MUST BE UNAFFECTED.
///
/// Android carries the user's real data. Adding two Flutter PLUGINS (native
/// code, not pure Dart) to `pubspec.yaml` is exactly the kind of change that
/// can quietly grow the Android build — a Gradle subproject, a manifest merge,
/// a registered plugin answering channels it should never see.
///
/// `.flutter-plugins-dependencies` is the file the Flutter tool WRITES on
/// every `pub get` and then READS to generate each platform's plugin
/// registrant. Asserting against it is therefore asserting against the real
/// registration decision, not against a comment or a hand-copied list — if a
/// future version of `tray_manager` ever shipped an Android implementation,
/// this test goes red before the APK does.
void main() {
  late Map<String, List<String>> pluginsByPlatform;

  setUpAll(() {
    final file = File('.flutter-plugins-dependencies');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run `flutter pub get` first — this test reads the resolved '
          'plugin map the Flutter tool generates',
    );
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final plugins = decoded['plugins'] as Map<String, dynamic>;
    pluginsByPlatform = plugins.map(
      (platform, entries) => MapEntry(
        platform,
        (entries as List<dynamic>)
            .map((e) => (e as Map<String, dynamic>)['name'] as String)
            .toList(),
      ),
    );
  });

  const trayPlugins = ['tray_manager', 'window_manager'];

  test('the tray pulled in no Android plugin transitively either', () {
    // Direct dependencies are the easy half. `window_manager` also drags in
    // the federated `screen_retriever` family, and a transitive plugin
    // registers on Android exactly as readily as a direct one — so the guard
    // has to be stated over the whole android list, not just the two packages
    // named in pubspec.yaml.
    final android = pluginsByPlatform['android']!;
    expect(
      android.where((name) =>
          name.contains('tray') ||
          name.contains('window_manager') ||
          name.contains('screen_retriever')),
      isEmpty,
    );
    // `screen_retriever_linux` DID arrive on the desktop side — proof the
    // assertion above is looking at a list that would have caught it.
    expect(pluginsByPlatform['linux'], contains('screen_retriever_linux'));
  });

  group('the tray plugins are registered on desktop only', () {
    for (final plugin in trayPlugins) {
      test('$plugin is registered for linux', () {
        expect(pluginsByPlatform['linux'], contains(plugin));
      });

      test('$plugin is NOT registered for android', () {
        // No Gradle subproject, no manifest merge, no entry in
        // GeneratedPluginRegistrant.java — nothing on the phone knows this
        // package exists.
        expect(pluginsByPlatform['android'] ?? const <String>[], isNot(contains(plugin)));
      });

      test('$plugin is NOT registered for ios', () {
        expect(pluginsByPlatform['ios'] ?? const <String>[], isNot(contains(plugin)));
      });

      test('$plugin is NOT registered for web', () {
        expect(pluginsByPlatform['web'] ?? const <String>[], isNot(contains(plugin)));
      });

      test('$plugin is ready for the windows/macos runners that do not exist yet', () {
        // These lists are populated from each plugin's own declared platforms,
        // independently of whether this repo has a `windows/` or `macos/`
        // folder. Their presence is what makes `flutter create
        // --platforms=windows` a build step rather than a rewrite.
        expect(pluginsByPlatform['windows'], contains(plugin));
        expect(pluginsByPlatform['macos'], contains(plugin));
      });
    }
  });

  test('the android plugin list is otherwise unchanged in shape', () {
    // A sanity check on the assertion itself: if the android list were empty
    // or missing, every "isNot(contains(...))" above would pass vacuously and
    // prove nothing.
    expect(pluginsByPlatform['android'], isNotNull);
    expect(pluginsByPlatform['android'], isNotEmpty);
    expect(pluginsByPlatform['android'], contains('flutter_secure_storage'));
  });
}
