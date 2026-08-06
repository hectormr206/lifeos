// The Settings row for the dictation shortcut.
//
// Two things are being protected here: that the row is ABSENT on the phone
// (where global shortcuts do not exist), and that a failure to register is
// visible in the row itself. A shortcut that quietly does not fire is
// indistinguishable from a broken keyboard, and the user has no way in.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/dictation/domain/dictation_hotkey.dart';
import 'package:lifeos/features/dictation/domain/global_hotkey_binder.dart';
import 'package:lifeos/features/dictation/presentation/dictation_hotkey_notifier.dart';
import 'package:lifeos/features/dictation/presentation/dictation_hotkey_tile.dart';
import 'package:lifeos/features/dictation/presentation/dictation_providers.dart';

class _FakeBinder implements GlobalHotkeyBinder {
  _FakeBinder({this.failWith});

  final Exception? failWith;

  @override
  Future<void> bind(DictationHotkey hotkey, void Function() onPressed) async {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> unbind() async {}
}

class _FakePrefs implements DictationHotkeyPreferences {
  String? stored;

  @override
  Future<String?> load() async => stored;

  @override
  Future<void> save(String value) async => stored = value;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required String os,
  Exception? bindFails,
}) async {
  final container = ProviderContainer(overrides: [
    hostOperatingSystemProvider.overrideWithValue(os),
    globalHotkeyBinderProvider
        .overrideWithValue(_FakeBinder(failWith: bindFails)),
    dictationHotkeyPreferencesProvider.overrideWithValue(_FakePrefs()),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: DictationHotkeyTile()),
    ),
  ));
  await container.read(dictationHotkeyProvider.notifier).ready;
  await tester.pump();
  return container;
}

void main() {
  testWidgets('on Linux it shows the shortcut currently in effect',
      (tester) async {
    await _pump(tester, os: 'linux');

    expect(find.text('Atajo para dictar'), findsOneWidget);
    expect(find.text('Super + Espacio'), findsOneWidget);
    expect(find.textContaining('desde cualquier lado'), findsOneWidget);
  });

  testWidgets('on Android the row is ABSENT — no global shortcuts there',
      (tester) async {
    await _pump(tester, os: 'android');

    expect(find.text('Atajo para dictar'), findsNothing);
  });

  testWidgets('a registration failure is shown in the row, not swallowed',
      (tester) async {
    await _pump(
      tester,
      os: 'linux',
      bindFails: const GlobalHotkeyUnavailableException(
          'falta la librería keybinder-3.0'),
    );

    expect(find.textContaining('keybinder-3.0'), findsOneWidget);
  });

  testWidgets('the change dialog refuses a modifier-less combination',
      (tester) async {
    // Pressing plain "A" would capture that key for every application on the
    // machine. Saying so before the user commits beats failing afterwards.
    await _pump(tester, os: 'linux');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Super + Espacio'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    expect(find.textContaining('tecla modificadora'), findsOneWidget);
    final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Guardar'));
    expect(save.onPressed, isNull, reason: 'it must not be savable');
  });
}
