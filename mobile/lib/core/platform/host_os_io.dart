import 'dart:io' show Platform;

/// IO (Android, iOS, Linux, macOS, Windows) half of the host-OS probe.
/// Reports the real OS name so the pure predicates in `app_platform.dart` can
/// route it.
String currentOperatingSystem() => Platform.operatingSystem;
