/// Web half of the host-OS probe. `dart:io`'s `Platform` does not exist in a
/// browser build, so there is no OS name to report. The `'web'` sentinel routes
/// to "not a native shell" in every predicate in `app_platform.dart`.
String currentOperatingSystem() => 'web';

/// A browser has no CPU architecture the update server publishes for, and no
/// desktop manifest to pick. The sentinel routes to "no update info".
String currentArchitecture() => 'web';
