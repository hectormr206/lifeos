import 'package:lifeos/features/local_model/domain/brain_model_manifest.dart';
import 'package:lifeos/features/local_model/domain/brain_model_update_gateway.dart';
import 'package:lifeos/features/local_model/domain/brain_model_version_store.dart';

/// In-memory [BrainModelUpdateGateway] for tests — no Dio, no
/// background_downloader, no filesystem. Scriptable manifest + download
/// outcomes; records calls so the notifier's OTA orchestration (check →
/// download → verify → install → track) is unit-testable on the host.
class FakeBrainModelUpdateGateway implements BrainModelUpdateGateway {
  FakeBrainModelUpdateGateway({
    this.configured = true,
    this.manifest,
    this.downloadResultPath = '/fake/brain_model/gemma-4-E2B-it.litertlm',
    this.downloadShouldFailVerification = false,
    List<double>? downloadProgress,
  }) : downloadProgress = downloadProgress ?? const [0.25, 0.5, 1.0];

  bool configured;

  /// What [fetchManifest] returns (null = fail-soft "no update info").
  BrainModelManifest? manifest;

  /// The verified local path [downloadAndVerify] resolves with.
  String downloadResultPath;

  /// When true, [downloadAndVerify] throws a sha256-mismatch-style
  /// [BrainModelDownloadException] AFTER emitting progress — the real gateway
  /// deletes the bogus file and throws, so the fake mirrors "rejected".
  bool downloadShouldFailVerification;

  final List<double> downloadProgress;

  int fetchManifestCount = 0;
  int downloadCount = 0;
  int deleteLocalFileCount = 0;
  BrainModelManifest? lastDownloadedManifest;

  @override
  bool get isConfigured => configured;

  @override
  Future<BrainModelManifest?> fetchManifest() async {
    fetchManifestCount++;
    return manifest;
  }

  @override
  Future<String> downloadAndVerify(
    BrainModelManifest manifest, {
    void Function(double progress)? onProgress,
  }) async {
    downloadCount++;
    lastDownloadedManifest = manifest;
    for (final p in downloadProgress) {
      onProgress?.call(p);
    }
    if (downloadShouldFailVerification) {
      throw BrainModelDownloadException(
        'La verificación del modelo falló; descarga descartada.',
      );
    }
    return downloadResultPath;
  }

  @override
  Future<void> deleteLocalFile() async {
    deleteLocalFileCount++;
  }
}

/// In-memory [BrainModelVersionStore] for tests (no shared_preferences
/// channel).
class FakeBrainModelVersionStore implements BrainModelVersionStore {
  // ignore: prefer_initializing_formals
  FakeBrainModelVersionStore({InstalledBrainModel? installed}) : _installed = installed;

  InstalledBrainModel? _installed;
  int writes = 0;
  int clears = 0;

  InstalledBrainModel? get value => _installed;

  @override
  Future<InstalledBrainModel?> installed() async => _installed;

  @override
  Future<void> setInstalled(InstalledBrainModel model) async {
    _installed = model;
    writes++;
  }

  @override
  Future<void> clear() async {
    _installed = null;
    clears++;
  }
}

/// Canned manifest builder for tests.
BrainModelManifest brainManifest({
  int versionCode = 2,
  String modelName = kBrainModelName,
  String filename = 'gemma-4-E2B-it.litertlm',
  String sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  int sizeBytes = 2600000000,
  String notes = 'Modelo re-afinado',
}) =>
    BrainModelManifest(
      modelName: modelName,
      versionCode: versionCode,
      filename: filename,
      sha256: sha256,
      sizeBytes: sizeBytes,
      notes: notes,
    );
