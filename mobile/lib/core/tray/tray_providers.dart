import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tray_controller_factory.dart';
import 'tray_labels.dart';
import 'tray_service.dart';
import 'tray_status.dart';

/// The app's single [TrayService], bound to the host it is running on.
///
/// On Android/iOS/web `TrayService.forHost` resolves to a platform
/// `trayIsSupportedOn` rejects, so [createTrayController] — the only reference
/// to `tray_manager`/`window_manager` in the whole app — is never invoked.
final trayServiceProvider = Provider<TrayService>(
  (ref) => TrayService.forHost(createController: createTrayController),
);

/// The tray's current state, as UI-renderable state.
///
/// Kept in Riverpod rather than inside the service alone so `TrayNotice` can
/// react to a failure the moment it happens. See `TrayStatus` for why a
/// failure has to be visible state at all.
final trayStatusProvider = NotifierProvider<TrayStatusNotifier, TrayStatus>(
  TrayStatusNotifier.new,
);

class TrayStatusNotifier extends Notifier<TrayStatus> {
  @override
  TrayStatus build() => const TrayPending();

  /// Installs the tray icon, or re-labels an existing one (language change).
  /// Never throws: a failure becomes [TrayUnavailable] state instead.
  Future<void> start(TrayMenuLabels labels) async {
    state = await ref.read(trayServiceProvider).start(labels);
  }

  /// Removes the icon so the desktop is not left with a ghost pointing at a
  /// dead process.
  Future<void> stop() async {
    await ref.read(trayServiceProvider).stop();
    state = ref.read(trayServiceProvider).status;
  }
}
