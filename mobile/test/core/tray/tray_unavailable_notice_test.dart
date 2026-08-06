import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/tray/tray_notice.dart';
import 'package:lifeos/core/tray/tray_providers.dart';
import 'package:lifeos/core/tray/tray_status.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _FixedTrayStatus extends TrayStatusNotifier {
  _FixedTrayStatus(this.fixed);

  final TrayStatus fixed;

  @override
  TrayStatus build() => fixed;
}

/// HOUSE RULE, rendered.
///
/// "A feature that cannot start must fail LOUDLY, never degrade quietly" only
/// means something if the failure reaches the user's eyes. On the target
/// machine the realistic cause is a Wayland session with no StatusNotifier
/// host — nothing the app can fix, and precisely the case where silently
/// showing no icon would be indistinguishable from the user not having looked
/// at his top bar yet.
void main() {
  Future<void> pump(WidgetTester tester, TrayStatus status) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trayStatusProvider.overrideWith(() => _FixedTrayStatus(status)),
        ],
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: TrayNotice(child: Text('contenido de la app')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says the tray is unavailable, and why', (tester) async {
    await pump(
      tester,
      TrayUnavailable(
        reason: 'No StatusNotifierHost is registered on this session bus.',
        error: StateError('x'),
        stackTrace: StackTrace.empty,
      ),
    );

    expect(find.text('Sin icono en la barra del sistema'), findsOneWidget);
    // The app is explicitly said to be fine, so the notice informs without
    // alarming.
    expect(find.textContaining('sigue funcionando'), findsOneWidget);
    // The underlying cause is shown, not hidden behind a generic apology —
    // it is the only thing that makes the message actionable.
    expect(find.textContaining('StatusNotifierHost'), findsOneWidget);
  });

  testWidgets('never hides the app behind the notice', (tester) async {
    await pump(
      tester,
      TrayUnavailable(
        reason: 'no host',
        error: StateError('x'),
        stackTrace: StackTrace.empty,
      ),
    );

    // The app is fully usable without a tray. The notice informs, it does not
    // block.
    expect(find.text('contenido de la app'), findsOneWidget);
  });

  testWidgets('can be dismissed, and stays dismissed', (tester) async {
    await pump(
      tester,
      TrayUnavailable(
        reason: 'no host',
        error: StateError('x'),
        stackTrace: StackTrace.empty,
      ),
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Sin icono en la barra del sistema'), findsNothing);
    expect(find.text('contenido de la app'), findsOneWidget);
  });

  testWidgets('shows NOTHING while the tray is active', (tester) async {
    await pump(tester, const TrayActive());

    expect(find.text('Sin icono en la barra del sistema'), findsNothing);
    expect(find.text('contenido de la app'), findsOneWidget);
  });

  testWidgets('shows NOTHING on Android — a phone has no tray to miss', (tester) async {
    // Crying wolf on every phone launch would train the user to ignore the
    // one case that matters.
    await pump(tester, const TrayNotApplicable('android'));

    expect(find.text('Sin icono en la barra del sistema'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('shows NOTHING before the tray has been attempted', (tester) async {
    await pump(tester, const TrayPending());

    expect(find.text('Sin icono en la barra del sistema'), findsNothing);
  });
}
