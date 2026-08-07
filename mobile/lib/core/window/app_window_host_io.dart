import '../tray/tray_hosts.dart';
import '../tray/tray_manager_hosts.dart';

/// Desktop half of the window-host seam. The adapter itself already exists —
/// `WindowManagerAppWindowHost` is what the tray controller drives — and it is
/// a stateless proxy over `window_manager`'s process-wide singleton, so a
/// second instance costs nothing and shares no state with the tray's.
///
/// Never constructed on Android/iOS: the only caller is guarded by
/// `trayShouldAutoStart()`, exactly like the tray controller factory.
AppWindowHost createAppWindowHost() => WindowManagerAppWindowHost();
