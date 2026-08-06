// GOLDEN: Axi's animated body, drawn natively by Flutter.
//
// HONEST SCOPE: these PNGs prove the drawing is STABLE and reproducible, not
// that it is beautiful. Nobody looked at the animation move while writing
// this — the machine is headless. What the goldens catch is a regression: a
// missing organ, a shifted limb, a colour change, a broken keyframe.
//
// Two images:
//   * axi_avatar.png        — the real AxiBodyWidget as the home screen shows
//                             it, at the first frame of the loop.
//   * axi_avatar_phases.png — three FIXED animation phases side by side
//                             (loop start, eyes shut mid-blink, heart at its
//                             first systole) so the keyframes are pinned too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_animation.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_geometry.dart';
import 'package:lifeos/features/axi_body/presentation/axi_avatar_painter.dart';
import 'package:lifeos/features/axi_body/presentation/axi_body_widget.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import 'support/golden_harness.dart';

/// Fixed instants of the loop, chosen so each one freezes a different organ
/// at a keyframe the CSS asset defined.
const _phases = <double>[
  0.0, // every track at its 0% frame
  5.5 * 0.96, // blink: lids fully shut
  2.0 * 0.09, // heartbeat: first systole (scale 1.18)
];

void main() {
  testWidgets('golden: Axi\'s native animated body on the home surface',
      (tester) async {
    useGoldenSurface(tester);

    await tester.pumpWidget(
      MaterialApp(
        theme: goldenTheme(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Center(child: AxiBodyWidget())),
      ),
    );
    // NOT pumpAndSettle: the idle loop never settles. One frame puts the
    // controller at value 0, which is the deterministic first frame.
    await tester.pump();

    await expectLater(
      find.byType(AxiBodyWidget),
      matchesGoldenFile('images/axi_avatar.png'),
    );
  });

  testWidgets('golden: three fixed animation phases', (tester) async {
    tester.view.physicalSize = const Size(220 * 3, 275) * kGoldenDpr;
    tester.view.devicePixelRatio = kGoldenDpr;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: const Key('phases'),
          child: ColoredBox(
            color: const Color(0xFFFFFFFF),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final seconds in _phases)
                  CustomPaint(
                    size: kAxiAvatarIntrinsicSize,
                    painter: AxiAvatarPainter(
                      elapsedSeconds: seconds,
                      pose: axiAvatarPoseAt(seconds),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    await expectLater(
      find.byKey(const Key('phases')),
      matchesGoldenFile('images/axi_avatar_phases.png'),
    );
  });
}
