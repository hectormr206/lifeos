import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

/// IO (Android, iOS, Linux, macOS, Windows) half of the host-OS probe.
/// Reports the real OS name so the pure predicates in `app_platform.dart` can
/// route it.
String currentOperatingSystem() => Platform.operatingSystem;

/// Machine architecture as reported by the Dart ABI (`linux_x64` → `x64`).
///
/// Used to pick the per-architecture desktop manifest. `Abi.current()` is the
/// only architecture probe that does not shell out to `uname`, which matters
/// because this runs on app start.
String currentArchitecture() {
  final abi = Abi.current().toString();
  final underscore = abi.lastIndexOf('_');
  return underscore == -1 ? abi : abi.substring(underscore + 1);
}
