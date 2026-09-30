import 'package:flutter/material.dart';

import '../../theme/lifeos_palette.dart';
import '../../theme/lifeos_tokens.dart';

/// Semantic tone for a notice, not a navigation action.
enum BannerTone { info, warning, success, error }

/// Compact status notice with a theme-aware container and readable foreground.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.tone,
    required this.icon,
    required this.message,
    this.action,
    this.margin = const EdgeInsets.symmetric(horizontal: kPageGutter, vertical: Space.sm),
  });

  final BannerTone tone;
  final IconData icon;
  final Widget message;
  final Widget? action;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = LifeOSPalette.of(context);
    final (background, foreground) = switch (tone) {
      BannerTone.info => (palette.infoContainer, palette.onInfoContainer),
      BannerTone.warning => (palette.warningContainer, palette.onWarningContainer),
      BannerTone.success => (palette.successContainer, palette.onSuccessContainer),
      BannerTone.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Radii.input),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: Space.md),
          Expanded(
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              child: message,
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: Space.md),
            action!,
          ],
        ],
      ),
    );
  }
}
