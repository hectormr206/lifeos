import 'dart:async';
import 'dart:typed_data';

import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_model_preferences.dart';
import 'package:lifeos/features/local_model/domain/notification_permission.dart';

/// A fully in-memory [LocalLlmEngine] for tests — NO flutter_gemma, no
/// download, no real inference. Records interactions and lets each behaviour
/// be scripted, so the on-device chat/model-manager logic is unit-testable on
/// the host without a device.
class FakeLocalLlmEngine implements LocalLlmEngine {
  FakeLocalLlmEngine({
    this._installed = false,
    List<double>? downloadProgress,
    this.downloadShouldFail = false,
    this.generateShouldFail = false,
    this.generateWithImagesShouldFail = false,
    this.deleteShouldFail = false,
    this.loadShouldFail = false,
    this.loadGate,
    this.generateGate,
    String Function(String prompt)? reply,
    String Function(String prompt)? imageReply,
    GenerationMetrics? metrics,
    GenerationMetrics? imageMetrics,
  })  : downloadProgress = downloadProgress ?? const [0.25, 0.5, 1.0],
        reply = reply ?? ((prompt) => 'eco: $prompt'),
        imageReply = imageReply ?? ((prompt) => 'veo la imagen: $prompt'),
        metrics = metrics ?? defaultMetrics,
        imageMetrics = imageMetrics ?? metrics ?? defaultMetrics;

  /// Canned metrics returned by [generate] unless a test injects its own — a
  /// realistic-looking GPU generation so the chat UI has numbers to render.
  static const GenerationMetrics defaultMetrics = GenerationMetrics(
    totalMs: 1200,
    tokensOut: 24,
    backend: LocalLlmBackend.gpu,
    modelId: 'gemma-4-E2B-it.litertlm',
    ttftMs: 150,
  );

  bool _installed;
  final List<double> downloadProgress;
  final bool downloadShouldFail;
  final bool generateShouldFail;
  final bool generateWithImagesShouldFail;
  final bool deleteShouldFail;

  /// When true, [load] throws so the model-load error/retry path is testable.
  /// Mutable so a test can flip it off and prove a "Reintentar" then succeeds.
  bool loadShouldFail;

  /// Optional gate that [load] awaits before completing — lets a widget test
  /// hold the engine in the "loading" state (banner visible, send disabled) and
  /// then release it to observe the transition to ready. Null = load resolves
  /// immediately.
  final Completer<void>? loadGate;

  /// Optional gate every [generate] awaits BEFORE producing its reply — lets a
  /// test hold a generation open and observe what a SECOND request does while
  /// the first is still running (the queue's whole reason to exist). Null =
  /// generation resolves immediately.
  final Completer<void>? generateGate;
  final String Function(String prompt) reply;
  final String Function(String prompt) imageReply;

  /// Metrics [generate] / [generateWithImages] attach to their result.
  final GenerationMetrics metrics;
  final GenerationMetrics imageMetrics;

  int loadCount = 0;
  int generateCount = 0;
  int generateWithImagesCount = 0;
  int deleteCount = 0;
  final List<String> prompts = [];
  final List<String> imagePrompts = [];

  /// Records the sampling passed to each [generate] / [generateWithImages] call
  /// so tests can assert the tuned constant (default) and the escape-temp retry
  /// override. Each entry is `(temperature, topK, topP)` — null when the caller
  /// omitted the override and the real engine falls back to the tuned constant.
  final List<(double?, int?, double?)> generateSampling = [];
  final List<(double?, int?, double?)> imageSampling = [];

  /// Records the images handed to [generateWithImages], so a test can assert the
  /// VISION path actually received the attachments. [lastImageBytes] is the
  /// first of the last batch (single-image convenience); [lastImages] is the
  /// whole batch.
  Uint8List? lastImageBytes;
  List<Uint8List>? lastImages;
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

  /// Paths handed to [installModelFromFile] (the brain-model OTA install/swap
  /// step), so tests can assert the verified LOCAL file reached the engine.
  final List<String> installedFromFilePaths = [];

  /// When true, [installModelFromFile] throws so the OTA install-failure path
  /// is testable.
  bool installFromFileShouldFail = false;

  @override
  Future<void> installModelFromFile(String path) async {
    installedFromFilePaths.add(path);
    if (installFromFileShouldFail) throw Exception('install boom');
    _installed = true;
  }

  @override
  Future<void> load({LocalLlmBackend? backend}) async {
    loadCount++;
    loadedBackend = backend;
    if (loadGate != null) await loadGate!.future;
    if (loadShouldFail) throw Exception('load boom');
  }

  @override
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  }) async {
    generateCount++;
    prompts.add(prompt);
    generateSampling.add((temperature, topK, topP));
    if (generateGate != null) await generateGate!.future;
    if (generateShouldFail) throw Exception('generate boom');
    return GenerationResult(text: reply(prompt), metrics: metrics);
  }

  @override
  Future<GenerationResult> generateWithImages(
    String prompt,
    List<Uint8List> images, {
    double? temperature,
    int? topK,
    double? topP,
  }) async {
    generateWithImagesCount++;
    imagePrompts.add(prompt);
    imageSampling.add((temperature, topK, topP));
    lastImages = images;
    lastImageBytes = images.isEmpty ? null : images.first;
    if (generateWithImagesShouldFail) throw Exception('vision boom');
    return GenerationResult(text: imageReply(prompt), metrics: imageMetrics);
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
  FakeLocalModelPreferences({this._enabled = false});

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
