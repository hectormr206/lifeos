/// Which of the app's capabilities actually exist on a given platform.
///
/// PRODUCT RULE (the user's words): "ocultar las cosas que no podamos hacer en
/// Linux o Pixel. Así cada uno tiene sus superpoderes." A capability the
/// platform does not have is ABSENT from the UI — not greyed out, not shown and
/// then throwing. Absent.
///
/// This is DISTINCT from the repo's fail-loudly rule, and both hold: a control
/// that is shown is a control that works, and if it is attempted and fails it
/// says so loudly. Hiding is only ever for capabilities that cannot exist here.
///
/// Every predicate takes the operating-system NAME as a parameter instead of
/// reading `Platform` inline — the same shape as
/// `core/tray/tray_platform.dart`'s `trayIsSupportedOn` and
/// `core/graph/graph_database_backend.dart`'s `graphDatabaseBackendFor`. That
/// is not a stylistic preference: the widget suite runs on a LINUX host, so
/// without the parameter there would be no way to assert on that host that the
/// ANDROID build still shows its Android-only rows. Android carries the user's
/// real data; "it did not regress" has to be provable, not assumed.
///
/// Unknown platform names deliberately answer `false` everywhere. A capability
/// is opt-in per platform, so a future shell shows a smaller, honest UI rather
/// than inheriting controls nobody has verified there.
library;

import 'host_os_io.dart' if (dart.library.html) 'host_os_web.dart' as host;

/// The three desktop shells, as opposed to the phones and the browser.
bool isDesktopPlatform(String operatingSystem) => switch (operatingSystem) {
      'linux' || 'macos' || 'windows' => true,
      _ => false,
    };

/// Whether the OS has a "default digital assistant" role an app can hold.
///
/// This is Android's `ACTION_ASSIST` / `VoiceInteractionService` (wired through
/// `MethodChannel('lifeos/assistant')`). Linux has no such concept — no
/// registry of assistants, nothing to be the default of — so the Settings row
/// that opens that system screen is hidden there rather than reworded.
bool supportsDefaultAssistantRole(String operatingSystem) =>
    operatingSystem == 'android';

/// Whether the OS asks the user to grant permissions at runtime.
///
/// `permission_handler` declares android and ios only. On the desktop shells
/// every `AppPermission` resolves to `PermissionState.unsupported` ("No
/// disponible"), so the whole Permissions surface is a list of things the user
/// cannot act on.
bool supportsRuntimePermissionPrompts(String operatingSystem) =>
    operatingSystem == 'android' || operatingSystem == 'ios';

/// Whether the app updates itself by installing a downloaded package.
///
/// Backs `AppPermission.installUnknownApps` (`REQUEST_INSTALL_PACKAGES`), which
/// only means something where the update IS an APK. The Linux updater is the
/// `lifeos-updater` systemd timer + service installed by
/// `tools/install-linux.sh`; nothing there needs a user grant.
bool supportsSideloadedApkInstall(String operatingSystem) =>
    operatingSystem == 'android';

/// Whether the Dictar button can work here.
///
/// It needs two things: a microphone reachable through the `record` package,
/// and the sherpa-onnx Whisper runtime for on-device transcription. Both are
/// present on the phones and on all three desktop shells. A browser build has
/// neither the plugin nor the model store, so the button is absent there.
///
/// NOTE on Linux specifically: `record_linux` captures by launching the
/// external `parecord` binary and encodes with `ffmpeg`. Neither is linked in,
/// so neither is visible to `ldd` — `tools/install-linux.sh` probes for them by
/// name. If they are missing the recorder fails at `start()`, and that failure
/// is reported loudly by the dictation controller; it is NOT a reason to hide
/// the button, because the capability exists on the platform and the fix is to
/// install a package.
bool supportsDictation(String operatingSystem) => switch (operatingSystem) {
      'android' || 'ios' || 'linux' || 'macos' || 'windows' => true,
      _ => false,
    };

/// Whether a shortcut can be registered with the OS so it fires from anywhere,
/// even while LifeOS is hidden in the tray.
///
/// Desktop only, and not for lack of trying elsewhere: Android and iOS have no
/// concept of an application claiming a system-wide key combination. The phone's
/// equivalent already exists and is a different mechanism entirely — the
/// assistant gesture (`ACTION_ASSIST`), wired through
/// `MethodChannel('lifeos/assistant')`. So the Settings row that configures a
/// hotkey is ABSENT on the phone rather than shown and inert.
bool supportsGlobalHotkeys(String operatingSystem) =>
    isDesktopPlatform(operatingSystem);

/// The operating-system name of the host this process is running on, with
/// `'web'` as the sentinel for a browser build (where `dart:io`'s `Platform`
/// does not exist at all). Resolved through the same conditional-import pattern
/// `core/tray/tray_platform.dart` and `core/tls/tls_adapter_factory.dart` use.
String currentOperatingSystem() => host.currentOperatingSystem();

/// The host CPU architecture in the naming the update server publishes under
/// (`x64`, `arm64`), or `'web'` in a browser build. Paired with
/// `updateArchFor` so an unrecognised value never becomes a wrong download.
String currentArchitecture() => host.currentArchitecture();
