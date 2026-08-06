import '../../l10n/app_localizations.dart';
import 'tray_labels.dart';

/// Bridges the generated localizations into the plugin-free [TrayMenuLabels]
/// value the tray code speaks.
///
/// It lives here, and not inside `core/tray`'s controllers, so that everything
/// below it stays free of `AppLocalizations` — that is what lets the tray
/// behaviour be tested without a widget tree, and it keeps the menu following
/// the app's language selector instead of freezing at whatever the locale
/// happened to be at first install.
TrayMenuLabels trayMenuLabelsFrom(AppLocalizations l10n) => TrayMenuLabels(
      tooltip: l10n.trayTooltip,
      showWindow: l10n.trayMenuShowWindow,
      quit: l10n.trayMenuQuit,
    );
