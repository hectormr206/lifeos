import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../tray/tray_hosts.dart';
import '../window/app_window_host_factory.dart';
import 'launch_options.dart';

/// How this process was launched.
///
/// Overridden in `main()` from the real entrypoint arguments. The default is a
/// normal, visible launch: a widget test has no argv, and defaulting to hidden
/// there would make every test render against a window nobody asked to hide.
final launchOptionsProvider =
    Provider<LaunchOptions>((ref) => LaunchOptions.visible);

/// The app window, for the one thing outside the tray that needs it: applying
/// a `--hidden` launch (`core/window/launch_visibility.dart`).
///
/// Constructed lazily. Its only reader is guarded by `trayShouldAutoStart()`,
/// so on Android/iOS/web and under `flutter test` nothing here is ever built
/// and `window_manager` is never touched.
final appWindowHostProvider =
    Provider<AppWindowHost>((ref) => createAppWindowHost());
