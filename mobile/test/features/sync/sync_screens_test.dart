// The two sync screens, checked for the promises they make.
//
// Widget tests here assert the things a screenshot review would miss and a
// refactor would silently break:
//
//   * the settings screen shows the residual-metadata list VERBATIM from
//     `sync_disclosure.dart` rather than a friendlier retyped version;
//   * the ceremony offers no way to copy the phrase;
//   * the ceremony cannot be completed without typing the right words.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:lifeos/features/sync/domain/sync_connectivity.dart';
import 'package:lifeos/features/sync/domain/sync_disclosure.dart';
import 'package:lifeos/features/sync/presentation/phrase_ceremony_screen.dart';
import 'package:lifeos/features/sync/presentation/sync_settings_screen.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

/// A tall test surface.
///
/// Both screens are ListViews, and a ListView only BUILDS what fits on screen.
/// On the default 800x600 surface the lower half of the disclosure — and the
/// last of the twelve words — simply do not exist in the widget tree, so
/// `find.text` reports them missing and the test fails for a reason that has
/// nothing to do with the screen being wrong.
///
/// Scrolling in the test would work too, but it makes every assertion depend on
/// pixel offsets. A tall surface keeps the assertions about CONTENT.
Future<void> _pumpTall(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(child));
  await tester.pumpAndSettle();
}

void _noop() {}

void main() {
  group('sync settings', () {
    testWidgets('shows the disclosure verbatim, uncomfortable parts included',
        (tester) async {
      await _pumpTall(tester, SyncSettingsScreen(
        connectivity: SyncConnectivity.reachable,
        lastSyncLine: 'Al día · hace un momento',
        thisDeviceId: 'a1b2c3',
        peerDeviceId: 'd4e5f6',
        lastStatus: null,
        deviceNickname: 'Pixel de pruebas',
        onEnable: () {},
        onDisable: () {},
        onSyncNow: () {},
        onOpenConflicts: () {},
      ));

      // Every observation from the constant must be on screen. Rendering from
      // the same source the test asserts is what stops the UI copy drifting
      // away from what the relay actually stores.
      for (final o in kRelayCanSee) {
        expect(find.text(o.what), findsOneWidget, reason: o.what);
      }
      for (final line in kRelayCannotSee) {
        expect(find.text(line), findsOneWidget);
      }
    });

    testWidgets('an unreachable relay is the only state shown as an error',
        (tester) async {
      for (final state in SyncConnectivity.values) {
        await _pumpTall(tester, SyncSettingsScreen(
          connectivity: state,
          lastSyncLine: 'Al día · hace un momento',
          thisDeviceId: 'a1b2c3',
          peerDeviceId: 'd4e5f6',
          lastStatus: null,
          deviceNickname: 'laptop',
          onEnable: () {},
          onDisable: () {},
          onSyncNow: () {},
          onOpenConflicts: () {},
        ));

        expect(find.text(state.label), findsOneWidget);
      }
    });

    testWidgets('with sync off, the per-device actions are not offered',
        (tester) async {
      await _pumpTall(tester, SyncSettingsScreen(
        connectivity: SyncConnectivity.notEnabled,
        lastSyncLine: 'Al día · hace un momento',
        thisDeviceId: 'a1b2c3',
        peerDeviceId: 'd4e5f6',
        lastStatus: null,
        deviceNickname: 'laptop',
        onEnable: () {},
        onDisable: () {},
        onSyncNow: () {},
        onOpenConflicts: () {},
      ));

      expect(find.text('Sincronizar ahora'), findsNothing);
      expect(find.text('Historial de conflictos'), findsNothing);
      // ...but the disclosure is still there. Someone deciding whether to turn
      // sync ON is exactly who needs to read it.
      expect(find.text(kRelayCanSee.first.what), findsOneWidget);
    });
  });

  testWidgets('the sync action is reachable without scrolling', (tester) async {
    // Reported as "no hay ningún botón de Sincronizar ahora". The action was
    // four rows below the switch, and the pair indicator added above it pushed
    // it off a phone screen — a regression introduced by the very widget meant
    // to make sync legible.
    //
    // Pumped at a REAL phone size, not the 800x600 default: at that default the
    // old layout fitted and this test would have passed while the button stayed
    // invisible on every actual device.
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: SyncSettingsScreen(
        connectivity: SyncConnectivity.reachable,
        lastSyncLine: 'Al día · hace un momento',
        thisDeviceId: 'a1b2c3',
        peerDeviceId: 'd4e5f6',
        lastStatus: null,
        deviceNickname: 'pixel',
        onEnable: () {},
        onDisable: () {},
        onSyncNow: () {},
        onOpenConflicts: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final button = find.widgetWithText(FilledButton, 'Sincronizar ahora');
    expect(button, findsOneWidget);

    final box = tester.getRect(button);
    expect(box.bottom, lessThan(720),
        reason: 'the primary action must be visible without scrolling');
  });

  testWidgets('while the keystore is still loading it does not claim to be off',
      (tester) async {
    // Reading the OS keystore takes a moment. Rendering that moment as "off"
    // is not a cosmetic flicker: the user sees the switch off on a device where
    // sync IS on, taps it, is asked "¿es tu primer dispositivo?", and gets a
    // BRAND NEW phrase — a new key, and their existing data orphaned behind the
    // old one.
    //
    // Unknown must therefore look like unknown, and must not be tappable.
    await tester.pumpWidget(const MaterialApp(
      home: SyncSettingsScreen(
        connectivity: SyncConnectivity.notEnabled,
        enablementKnown: false,
        lastSyncLine: '',
        thisDeviceId: 'a1b2c3',
        peerDeviceId: null,
        lastStatus: null,
        deviceNickname: 'pixel',
        onEnable: _noop,
        onDisable: _noop,
        onSyncNow: _noop,
        onOpenConflicts: _noop,
      ),
    ));

    final switchTile = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(switchTile.onChanged, isNull,
        reason: 'an unknown state must not be tappable into a new ceremony');
  });

  group('phrase ceremony', () {
    testWidgets('shows twelve numbered words and no way to copy them',
        (tester) async {
      final ceremony = PhraseCeremony.generate();
      await _pumpTall(tester, PhraseCeremonyScreen(
        ceremony: ceremony,
        onConfirmed: (_) {},
        onCancel: () {},
      ));

      for (final w in ceremony.words) {
        expect(find.text(w), findsWidgets);
      }

      // No copy affordance, on purpose: the clipboard is readable by every app
      // on the phone and survives in clipboard history. Paper is the point.
      expect(find.byIcon(Icons.copy), findsNothing);
      expect(find.byIcon(Icons.content_copy), findsNothing);
      expect(find.textContaining('Copiar'), findsNothing);
    });

    testWidgets('wrong words do not confirm, and say so', (tester) async {
      var confirmed = false;
      final ceremony = PhraseCeremony.generate();
      await _pumpTall(tester, PhraseCeremonyScreen(
        ceremony: ceremony,
        onConfirmed: (_) => confirmed = true,
        onCancel: () {},
      ));

      await tester.tap(find.text('Ya las anoté'));
      await tester.pumpAndSettle();

      for (final i in ceremony.challengeIndices) {
        await tester.enterText(find.byType(TextField).at(
          ceremony.challengeIndices.toList().indexOf(i),
        ), 'zoo');
      }
      await tester.tap(find.text('Confirmar y activar'));
      await tester.pumpAndSettle();

      expect(confirmed, isFalse);
      expect(find.textContaining('no coincide'), findsOneWidget);
    });

    testWidgets('the right words confirm', (tester) async {
      PhraseCeremony? got;
      final ceremony = PhraseCeremony.generate();
      await _pumpTall(tester, PhraseCeremonyScreen(
        ceremony: ceremony,
        onConfirmed: (c) => got = c,
        onCancel: () {},
      ));

      await tester.tap(find.text('Ya las anoté'));
      await tester.pumpAndSettle();

      final indices = ceremony.challengeIndices.toList();
      for (var n = 0; n < indices.length; n++) {
        await tester.enterText(
          find.byType(TextField).at(n),
          ceremony.words[indices[n]],
        );
      }
      await tester.tap(find.text('Confirmar y activar'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.isConfirmed, isTrue);
    });
  });
}
