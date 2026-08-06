import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'tray_providers.dart';
import 'tray_status.dart';

/// The house rule made visible: when the system tray cannot be brought up on a
/// platform that should have one, LifeOS SAYS SO.
///
/// Wraps the whole app (installed in `MaterialApp.router`'s `builder`, inside
/// `AppLockGate` so a locked app shows nothing but the lock screen). It is a
/// pass-through in every state except [TrayUnavailable] — including
/// [TrayNotApplicable], because telling a phone user his system tray is
/// missing would be crying wolf on every single launch and would train him to
/// ignore the one case that matters.
///
/// It informs, it never blocks: the app is entirely usable without a tray, so
/// the content stays visible and the notice can be dismissed.
class TrayNotice extends ConsumerStatefulWidget {
  const TrayNotice({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<TrayNotice> createState() => _TrayNoticeState();
}

class _TrayNoticeState extends ConsumerState<TrayNotice> {
  /// Dismissed for this run only. Deliberately NOT persisted: if the tray
  /// fails again on the next launch, that is worth saying again.
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(trayStatusProvider);
    if (status is! TrayUnavailable || _dismissed) return widget.child;

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(
      children: [
        Material(
          color: theme.colorScheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      // REQUIRED, not tidiness. In `MaterialApp.router`'s
                      // builder the notice is the first child of a Column, so
                      // it is laid out with an UNBOUNDED height — and a nested
                      // `MainAxisSize.max` Column under infinite height takes
                      // all of it, blowing up the banner to 100 000 px. Caught
                      // by `app_tray_wiring_test.dart`, which renders the
                      // notice in that exact position rather than in a
                      // convenient Scaffold.
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.trayUnavailableTitle,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // The underlying cause is shown, not hidden behind a
                          // generic apology — it is the only part of this
                          // message the user can act on.
                          l10n.trayUnavailableMessage(status.reason),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // The explicit size is REQUIRED, not cosmetic. This notice
                  // is the first child of a Column with an Expanded sibling,
                  // so it is laid out with an unbounded height — and a Row
                  // measures its non-flex children with an unbounded width
                  // too. `IconButton` centres its icon, and a Center under
                  // unbounded constraints expands to fill them, which blew the
                  // banner up to 100 000 px in both axes. Caught by
                  // `app_tray_wiring_test.dart`, which renders the notice in
                  // its real position instead of a convenient Scaffold.
                  SizedBox.square(
                    dimension: 32,
                    // Labelled with Semantics rather than IconButton's
                    // `tooltip:`. A Tooltip needs an Overlay ancestor, and
                    // this notice is installed in `MaterialApp.router`'s
                    // builder — ABOVE the app's Navigator, so there is no
                    // Overlay above it to float in. Same test caught this.
                    child: Semantics(
                      label: l10n.actionClose,
                      button: true,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        icon: const Icon(Icons.close),
                        color: theme.colorScheme.onErrorContainer,
                        onPressed: () => setState(() => _dismissed = true),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
