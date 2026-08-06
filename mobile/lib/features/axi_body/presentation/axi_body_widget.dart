import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/axi_organ_actions.dart';
import 'axi_avatar_animation.dart';
import 'axi_avatar_geometry.dart';
import 'axi_avatar_painter.dart';

/// Axi's animated body on the home screen — the laptop dashboard's living
/// avatar, drawn NATIVELY by Flutter.
///
/// It used to be the same SVG running inside a WebView backed by a bundled
/// asset. That worked on Android and iOS and nowhere else: `webview_flutter`
/// has no Linux implementation, so the desktop build fell through to a static
/// PNG of Axi's head — a motionless mascot on the very machine the assistant
/// is developed on. A [CustomPainter] has no such gap: Android, Linux and
/// later Windows/macOS/web all get the same moving Axi with no extra work and
/// no embedded browser.
///
/// The drawing lives in [AxiAvatarPainter], the idle motion in
/// [axiAvatarPoseAt] and the organ shapes in [axiOrganAtViewBox] — all
/// transcribed from the original SVG and its CSS keyframes.
///
/// Organ taps are resolved by [kAxiOrganRoutes]; organs without a mobile
/// equivalent yet show a localized "próximamente" snackbar.
class AxiBodyWidget extends StatefulWidget {
  const AxiBodyWidget({super.key});

  /// Avatar viewport height; matches the SVG's 220x275 intrinsic size.
  static const double height = 285;

  @override
  State<AxiBodyWidget> createState() => _AxiBodyWidgetState();
}

class _AxiBodyWidgetState extends State<AxiBodyWidget>
    with SingleTickerProviderStateMixin {
  /// Ticks over one full body loop; see [kAxiAvatarLoop] for why that period.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kAxiAvatarLoop,
  );

  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The asset honoured `@media (prefers-reduced-motion: reduce)`; the
    // platform flag behind it is MediaQuery's `disableAnimations`.
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce == _reduceMotion) return;
    _reduceMotion = reduce;
    if (reduce) {
      _controller.stop();
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapUp(TapUpDetails details, Size size) {
    final organ = axiOrganAtViewBox(axiViewBoxPoint(details.localPosition, size));
    if (organ == null) return;

    final route = axiOrganRoute(organ);
    if (route != null) {
      context.push(route);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).axiOrganComingSoon)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      label: l10n.axiAvatarLabel,
      child: SizedBox(
        height: AxiBodyWidget.height,
        child: Center(
          child: SizedBox.fromSize(
            size: kAxiAvatarIntrinsicSize,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _onTapUp(details, kAxiAvatarIntrinsicSize),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final seconds =
                      _controller.value * kAxiAvatarLoop.inMilliseconds / 1000;
                  return CustomPaint(
                    size: kAxiAvatarIntrinsicSize,
                    painter: AxiAvatarPainter(
                      elapsedSeconds: seconds,
                      pose: _reduceMotion
                          ? kAxiAvatarRestPose
                          : axiAvatarPoseAt(seconds),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
