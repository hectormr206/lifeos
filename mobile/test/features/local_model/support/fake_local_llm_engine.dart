import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_model_preferences.dart';
import 'package:lifeos/features/local_model/domain/notification_permission.dart';

/// A fully in-memory [LocalLlmEngine] for tests — NO flutter_gemma, no
/// download, no real inference. Records interactions and lets each behaviour
/// be scripted, so the on-device chat/model-manager logic is unit-testable on
/// the host without a device.
class FakeLocalLlmEngine implements LocalLlmEngine {
  FakeLocalLlmEngine({
    bool installed = false,
    List<double>? downloadProgress,
    this.downloadShouldFail = false,
    this.generateShouldFail = false,
    this.deleteShouldFail = false,
    String Function(String prompt)? reply,
  })  : _installed = installed,
        downloadProgress = downloadProgress ?? const [0.25, 0.5, 1.0],
        reply = reply ?? ((prompt) => 'eco: $prompt');

  bool _installed;
  final List<double> downloadProgress;
  final bool downloadShouldFail;
  final bool generateShouldFail;
  final bool deleteShouldFail;
  final String Function(String prompt) reply;

  int loadCount = 0;
  int generateCount = 0;
  int deleteCount = 0;
  final List<String> prompts = [];
  bool disposed = false;
  LocalLlmBackend? loadedBackend;

  @override
  Future<bool> isModelInstalled() async => _installed;

  @override
  Stream<double> downloadModel() async* {
    if (downloadShouldFail) throw Exception('download boom');
    for (final p in downloadProgress) {
      yield p;
    }
    _installed = true;
  }

  @override
  Future<void> load({LocalLlmBackend? backend}) async {
    loadCount++;
    loadedBackend = backend;
  }

  @override
  Future<String> generate(String prompt) async {
    generateCount++;
    prompts.add(prompt);
    if (generateShouldFail) throw Exception('generate boom');
    return reply(prompt);
  }

  @override
  Future<void> deleteModel() async {
    deleteCount++;
    // Real engine unloads before deleting; mirror that so tests can assert it.
    disposed = true;
    if (deleteShouldFail) throw Exception('delete boom');
    _installed = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// In-memory [NotificationPermissionGateway] for tests — no permission_handler
/// channel, no OS dialog. Scriptable request/status outcomes; counts requests +
/// openSettings calls so the notifier's request/re-request/open-settings
/// behaviour is unit-testable on the host.
class FakeNotificationPermissionGateway implements NotificationPermissionGateway {
  FakeNotificationPermissionGateway({
    this.requestResult = NotificationPermission.granted,
    NotificationPermission? statusResult,
    this.openSettingsResult = true,
  }) : statusResult = statusResult ?? requestResult;

  /// What [request] returns; mutable so a test can flip it between calls.
  NotificationPermission requestResult;

  /// What [status] returns.
  NotificationPermission statusResult;

  /// What [openSettings] returns.
  bool openSettingsResult;

  int requestCount = 0;
  int statusCount = 0;
  int openSettingsCount = 0;

  @override
  Future<NotificationPermission> request() async {
    requestCount++;
    return requestResult;
  }

  @override
  Future<NotificationPermission> status() async {
    statusCount++;
    return statusResult;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCount++;
    return openSettingsResult;
  }
}

/// In-memory [LocalModelPreferences] for tests (no shared_preferences channel).
class FakeLocalModelPreferences implements LocalModelPreferences {
  FakeLocalModelPreferences({bool enabled = false}) : _enabled = enabled;

  bool _enabled;
  int writes = 0;

  @override
  Future<bool> isEnabled() async => _enabled;

  @override
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    writes++;
  }
}
