import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../tts/domain/piper_speech_synthesizer.dart';
import '../../tts/domain/tts_voice.dart';
import '../../tts/presentation/tts_providers.dart';
import '../domain/selected_voice.dart';
import '../domain/voice_catalog.dart';

/// A one-shot notice the catalog picker surfaces to the user (as a SnackBar).
/// Currently only fires when a previewed voice is INCOMPATIBLE with this
/// device — the pre-synthesis guard refused it instead of letting the engine
/// crash. The screen listens, shows the localized message, and resets it to
/// null so the same notice can fire again later.
enum VoicePreviewNotice { incompatibleVoice }

/// Ephemeral channel for [VoicePreviewNotice]. Null when there is nothing to
/// show; the picker screen consumes it and calls [VoicePreviewNoticeNotifier.clear].
///
/// A [NotifierProvider] (not the legacy `StateProvider`, which riverpod 3 keeps
/// only under `flutter_riverpod/legacy`) to match this codebase's convention.
final voicePreviewNoticeProvider =
    NotifierProvider<VoicePreviewNoticeNotifier, VoicePreviewNotice?>(
        VoicePreviewNoticeNotifier.new);

class VoicePreviewNoticeNotifier extends Notifier<VoicePreviewNotice?> {
  @override
  VoicePreviewNotice? build() => null;

  /// Raises [notice] for the screen to surface.
  void show(VoicePreviewNotice notice) => state = notice;

  /// Clears the pending notice after it has been shown.
  void clear() => state = null;
}

/// Local-only persistence of the chosen voice id. Overridden with a fake in
/// tests. Lives in its OWN provider (no chat import) so any layer can read the
/// selection without an import cycle.
final selectedVoicePreferencesProvider = Provider<SelectedVoicePreferences>(
  (ref) => SharedPrefsSelectedVoicePreferences(),
);

/// The user's persisted voice id (e.g. `es_MX-claude`). Hydrates asynchronously
/// from [selectedVoicePreferencesProvider] without blocking first read;
/// defaults to [VoiceCatalog.defaultVoice] until persistence resolves. Read live
/// by the TTS gateway at speak-time so a pick applies to the next utterance
/// without rebuilding the shared engine.
final selectedVoiceProvider =
    NotifierProvider<SelectedVoiceNotifier, String>(SelectedVoiceNotifier.new);

class SelectedVoiceNotifier extends Notifier<String> {
  Future<void>? _hydration;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  String build() {
    _hydration = _hydrate();
    return VoiceCatalog.defaultVoice.id;
  }

  Future<void> _hydrate() async {
    try {
      final stored = await ref.read(selectedVoicePreferencesProvider).load();
      // Accept a known catalog voice OR the system-voice sentinel (persisted
      // after the user deletes their selected voice with none left). Ignore any
      // other unknown/legacy id so a stale preference can never point the engine
      // at a voice that is no longer in the catalog.
      if (stored != null &&
          (VoiceCatalog.contains(stored) || stored == VoiceCatalog.systemVoiceId)) {
        state = stored;
      }
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // stay on the shipped default rather than crashing.
    }
  }

  /// Selects [voiceId] as the active voice: persists it, then ensures it is
  /// downloaded (a not-yet-installed voice triggers its download first — the
  /// catalog controller no-ops when it is already on disk). Ignores unknown ids.
  Future<void> select(String voiceId) async {
    if (!VoiceCatalog.contains(voiceId) || voiceId == state) {
      if (VoiceCatalog.contains(voiceId)) {
        await ref.read(voiceCatalogControllerProvider.notifier).download(voiceId);
      }
      return;
    }
    state = voiceId;
    try {
      await ref.read(selectedVoicePreferencesProvider).save(voiceId);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
    await ref.read(voiceCatalogControllerProvider.notifier).download(voiceId);
  }

  /// Moves the selection to [voiceId] after the current voice was deleted:
  /// persists it but does NOT trigger any download. [voiceId] is either an
  /// already-installed voice or [VoiceCatalog.systemVoiceId] — a deleted voice
  /// must never be auto-redownloaded, so this deliberately skips the
  /// download step that [select] performs.
  Future<void> fallbackTo(String voiceId) async {
    state = voiceId;
    try {
      await ref.read(selectedVoicePreferencesProvider).save(voiceId);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the fallback.
    }
  }
}

/// Per-voice install/download status for the whole catalog, keyed by voice id.
/// Drives the catalog picker (install badge, progress bar) and, for the
/// selected voice, the Voz screen status card. The ACTUAL download logic lives
/// once in [TtsVoiceGateway]; this notifier is a thin state adapter over it.
final voiceCatalogControllerProvider =
    NotifierProvider<VoiceCatalogController, Map<String, TtsVoiceStatus>>(
        VoiceCatalogController.new);

class VoiceCatalogController extends Notifier<Map<String, TtsVoiceStatus>> {
  final Set<String> _inFlight = {};
  Future<void>? _hydration;

  /// Lets tests await the initial installed-state probe deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  Map<String, TtsVoiceStatus> build() {
    _hydration = _refreshInstalled();
    return {for (final voice in VoiceCatalog.all) voice.id: const TtsVoiceAbsent()};
  }

  /// The status of [voiceId], defaulting to absent for an unknown id.
  TtsVoiceStatus statusOf(String voiceId) => state[voiceId] ?? const TtsVoiceAbsent();

  /// Probes each catalog voice on disk and marks the installed ones Ready.
  /// Fail-soft: a probe error just leaves that voice Absent.
  Future<void> _refreshInstalled() async {
    final gateway = ref.read(ttsVoiceGatewayProvider);
    for (final voice in VoiceCatalog.all) {
      try {
        // `await` first so no `state` read happens synchronously during build.
        final installed = await gateway.installedVoice(voice.id);
        if (installed != null && state[voice.id] is! TtsVoiceDownloading) {
          _set(voice.id, const TtsVoiceReady());
        }
      } catch (_) {
        // Probe failure reads as "not installed".
      }
    }
  }

  /// Downloads [voiceId], streaming progress into its entry. No-op when a
  /// download for it is already in flight; when it is already on disk it just
  /// lands Ready without fetching. Never throws — a failure lands Failed.
  Future<void> download(String voiceId) async {
    if (!VoiceCatalog.contains(voiceId) || _inFlight.contains(voiceId)) return;
    _inFlight.add(voiceId);
    try {
      final gateway = ref.read(ttsVoiceGatewayProvider);
      if (await gateway.installedVoice(voiceId) != null) {
        _set(voiceId, const TtsVoiceReady());
        return;
      }
      _set(voiceId, const TtsVoiceDownloading(0));
      await gateway.download(
        voiceId,
        onProgress: (p) => _set(voiceId, TtsVoiceDownloading(p)),
      );
      _set(voiceId, const TtsVoiceReady());
    } catch (e) {
      _set(voiceId, TtsVoiceFailed(e.toString()));
    } finally {
      _inFlight.remove(voiceId);
    }
  }

  /// Plays a short sample sentence with [voiceId], downloading it first when it
  /// is not yet installed. Best-effort: a generic failure is swallowed (a broken
  /// preview must never crash the picker). An INCOMPATIBLE voice, though,
  /// surfaces a [VoicePreviewNotice.incompatibleVoice] notice so the user learns
  /// why nothing played — the guard refused it instead of crashing the app.
  Future<void> preview(String voiceId, String sampleText) async {
    try {
      final gateway = ref.read(ttsVoiceGatewayProvider);
      var paths = await gateway.installedVoice(voiceId);
      if (paths == null) {
        await download(voiceId);
        paths = await gateway.installedVoice(voiceId);
      }
      if (paths == null) return;
      await ref.read(ttsPreviewProvider).play(voice: paths, text: sampleText);
    } on UnsupportedVoiceException {
      ref.read(voicePreviewNoticeProvider.notifier).show(
            VoicePreviewNotice.incompatibleVoice,
          );
    } catch (_) {
      // Best-effort preview.
    }
  }

  /// Deletes the on-disk files of [voiceId] and marks it Absent. When it was
  /// the SELECTED voice, selection falls back — WITHOUT re-downloading — to
  /// another already-installed voice if one exists, otherwise to the
  /// device/system voice ([VoiceCatalog.systemVoiceId]). Ignores unknown ids;
  /// never throws (a filesystem error still lands the voice Absent).
  Future<void> delete(String voiceId) async {
    if (!VoiceCatalog.contains(voiceId)) return;
    try {
      await ref.read(ttsVoiceGatewayProvider).deleteVoice(voiceId);
    } catch (_) {
      // Best-effort: even a partial delete still reads as no-longer-installed.
    }
    _set(voiceId, const TtsVoiceAbsent());
    if (ref.read(selectedVoiceProvider) == voiceId) {
      final replacement = _firstInstalledOther(voiceId) ?? VoiceCatalog.systemVoiceId;
      await ref.read(selectedVoiceProvider.notifier).fallbackTo(replacement);
    }
  }

  /// The id of the first still-installed catalog voice other than [excludeId],
  /// or null when none remains installed.
  String? _firstInstalledOther(String excludeId) {
    for (final voice in VoiceCatalog.all) {
      if (voice.id == excludeId) continue;
      if (state[voice.id] is TtsVoiceReady) return voice.id;
    }
    return null;
  }

  void _set(String voiceId, TtsVoiceStatus status) =>
      state = {...state, voiceId: status};
}
