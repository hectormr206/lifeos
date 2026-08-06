// Proves Axi's animated body is drawn NATIVELY by Flutter on every platform:
// no WebView, no bundled HTML, no static-image fallback. The old widget
// rendered a WebView and degraded to a motionless PNG wherever
// `webview_flutter` has no implementation (Linux desktop, the test host);
// this suite pins the replacement's behaviour.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_animation.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_geometry.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_painter.dart';
import 'package:lifeos/features/axi_body/presentation/axi_body_widget.dart';
import 'package:lifeos/l10n/app_localizations.dart';

/// Records where the app navigated so organ taps can be asserted.
final _visited = <String>[];

GoRouter _router() => GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: AxiBodyWidget()),
        ),
        for (final path in const ['/brain3d', '/settings/graph', '/body', '/chat'])
          GoRoute(
            path: path,
            builder: (_, _) {
              _visited.add(path);
              return const Scaffold(body: Text('elsewhere'));
            },
          ),
      ],
    );

Widget _app(GoRouter router, {bool reduceMotion = false}) => MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
    );

final _avatarPaint = find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is AxiAvatarPainter);

AxiAvatarPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_avatarPaint).painter! as AxiAvatarPainter;

/// Taps the point in the avatar's 64x80 viewBox space.
Future<void> _tapOrgan(WidgetTester tester, Offset viewBoxPoint) async {
  final box = tester.getRect(_avatarPaint);
  final scale = box.width / kAxiAvatarViewBox.width;
  await tester.tapAt(box.topLeft + viewBoxPoint * scale);
  // NOT pumpAndSettle: the idle animation never stops, by design.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(_visited.clear);

  testWidgets('renders a native CustomPaint avatar, never a static fallback',
      (tester) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pump();

    expect(_painter(tester), isA<AxiAvatarPainter>());
    // The old WebView-less fallback was `Image.asset('assets/branding/...')`.
    expect(
      find.descendant(
          of: find.byType(AxiBodyWidget), matching: find.byType(Image)),
      findsNothing,
    );
  });

  testWidgets('keeps its public API: fixed height and the semantics label',
      (tester) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pump();

    expect(AxiBodyWidget.height, 285);
    expect(tester.getSize(find.byType(AxiBodyWidget)).height, 285);
    expect(
      find.bySemanticsLabel('Axi — agente vivo. Toca un órgano para explorarlo.'),
      findsOneWidget,
    );
  });

  testWidgets('the animation advances frame to frame', (tester) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pump();
    final first = _painter(tester).elapsedSeconds;

    await tester.pump(const Duration(milliseconds: 250));
    final second = _painter(tester).elapsedSeconds;

    expect(second, greaterThan(first));
    // ...and it is a loop, not a one-shot: still running much later.
    await tester.pump(const Duration(seconds: 30));
    expect(_painter(tester).elapsedSeconds, greaterThan(second));
  });

  testWidgets('holds still when the platform asks for reduced motion',
      (tester) async {
    await tester.pumpWidget(_app(_router(), reduceMotion: true));
    await tester.pump();
    final pose = _painter(tester).pose;

    await tester.pump(const Duration(seconds: 3));

    expect(_painter(tester).pose, pose);
    expect(pose, kAxiAvatarRestPose);
  });

  testWidgets('disposes its ticker when removed (no leaked animation)',
      (tester) async {
    await tester.pumpWidget(_app(_router()));
    await tester.pump();
    // A leaked ticker makes flutter_test fail this test on teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  group('organ taps navigate exactly like the JS channel did', () {
    for (final probe in const <(String, Offset, String)>[
      ('brain', Offset(32, 30.3), '/brain3d'),
      ('memory', Offset(32, 60), '/settings/graph'),
      ('heart', Offset(32, 55.5), '/body'),
      ('lungs', Offset(15, 43.5), '/body'),
      ('eyes', Offset(26, 38), '/chat'),
      ('ears', Offset(17, 28), '/chat'),
      ('mouth', Offset(32, 45), '/chat'),
    ]) {
      testWidgets('${probe.$1} -> ${probe.$3}', (tester) async {
        await tester.pumpWidget(_app(_router()));
        await tester.pump();
        await _tapOrgan(tester, probe.$2);
        expect(_visited, [probe.$3]);
      });
    }

    testWidgets('an organ with no mobile screen yet shows "próximamente"',
        (tester) async {
      await tester.pumpWidget(_app(_router()));
      await tester.pump();
      await _tapOrgan(tester, const Offset(25.5, 67.5)); // feet
      expect(_visited, isEmpty);
      expect(find.text('Próximamente en este dispositivo'), findsOneWidget);
    });

    testWidgets('tapping empty canvas does nothing at all', (tester) async {
      await tester.pumpWidget(_app(_router()));
      await tester.pump();
      await _tapOrgan(tester, const Offset(2, 2));
      expect(_visited, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('builds on every target platform without a WebView', () {
    for (final platform in TargetPlatform.values) {
      testWidgets('renders on $platform', (tester) async {
        debugDefaultTargetPlatformOverride = platform;

        await tester.pumpWidget(_app(_router()));
        await tester.pump(const Duration(milliseconds: 500));

        expect(_painter(tester), isA<AxiAvatarPainter>());
        expect(tester.takeException(), isNull);
        // Reset inside the body: flutter_test checks foundation debug vars
        // before tearDown callbacks run.
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
