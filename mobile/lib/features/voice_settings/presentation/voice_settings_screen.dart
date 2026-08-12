import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_providers.dart';
import '../../tts/domain/tts_voice.dart';
import '../../tts/domain/voice_test_outcome.dart';
import '../domain/voice_catalog.dart';
import '../domain/voice_settings.dart';
import 'voice_catalog_providers.dart';
import 'voice_settings_providers.dart';
import '../../dictation/presentation/dictation_hotkey_tile.dart';

/// Settings → "Voz": the DELIBERATELY MINIMAL speak-aloud screen. One curated
/// neural voice (Piper es_MX / en_US, following the app language), a good
/// shipped default, and just three controls:
///
///  1. "Responder por voz" — Axi reads every reply aloud (default ON, the same
///     shared preference the chat app-bar toggle uses).
///  2. A voice-status card — proactively downloads the neural Piper voice (with
///     progress) so Axi stops using the robotic system fallback, then shows it
///     as active. A "Descargar voz natural" / "Reintentar" action covers the
///     absent / failed states.
///  3. One speech-RATE slider (slow ↔ fast), persisted and applied to BOTH
///     engines, plus a "Probar voz" button that speaks a neutral-Spanish sample.
///
/// SEAM for a future curated-voice picker: the model already carries a tuned
/// [VoiceSettings.pitch] (no UI today) and the download layer is per-language;
/// adding 2-3 curated voices later means a picker here + a voice id in the
/// gateway, without touching this screen's shape.
///
/// Offline-reachable / not pairing-gated — everything here is local.
class VoiceSettingsScreen extends ConsumerStatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  ConsumerState<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends ConsumerState<VoiceSettingsScreen> {
  /// Live slider value while dragging (persisted only on release), so a drag
  /// stays smooth without a shared_preferences write per tick.
  double? _dragRate;

  /// Whether a voice test is running RIGHT NOW. The neural synthesis can take
  /// tens of seconds on a cold engine, and the button used to look dead for
  /// all of it: this drives the spinner (immediate acknowledgement) and
  /// disables the button, because every extra tap started ANOTHER synthesis
  /// run and made the wait longer.
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    // Proactively make the NEURAL voice the active one: probe + download the
    // SELECTED voice on open. No-op if already installed (lands Ready) or a
    // download is already in flight. Fire-and-forget — the status card reflects
    // progress via the catalog controller entry for the selected voice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(voiceCatalogControllerProvider.notifier)
          .download(ref.read(selectedVoiceProvider));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final autoSpeak = ref.watch(voiceReplyEnabledProvider);
    final settings = ref.watch(voiceSettingsProvider);
    final selectedVoice = ref.watch(selectedVoiceProvider);
    final voiceStatus =
        ref.watch(voiceCatalogControllerProvider)[selectedVoice] ?? const TtsVoiceAbsent();
    final rate = _dragRate ?? settings.rate;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.voiceScreenTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Desktop only; renders as nothing on the phones, where a global
          // shortcut does not exist (the assistant gesture is that surface).
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: DictationHotkeyTile(),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.record_voice_over_outlined),
            title: Text(l10n.voiceAutoSpeakTitle),
            subtitle: Text(l10n.voiceAutoSpeakSubtitle),
            value: autoSpeak,
            onChanged: (value) =>
                ref.read(voiceReplyEnabledProvider.notifier).setEnabled(value),
          ),
          const Divider(),
          _VoiceStatusCard(status: voiceStatus),
          ListTile(
            leading: const Icon(Icons.tune_outlined),
            title: Text(l10n.voiceCatalogNavTitle),
            subtitle: Text(
              '${VoiceCatalog.byId(selectedVoice)?.displayName ?? selectedVoice} · '
              '${l10n.voiceCatalogNavSubtitle}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/voice/catalog'),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l10n.voiceRateLabel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(l10n.voiceRateSlow, style: Theme.of(context).textTheme.bodySmall),
                Expanded(
                  child: Slider(
                    value: rate.clamp(VoiceSettings.minRate, VoiceSettings.maxRate),
                    min: VoiceSettings.minRate,
                    max: VoiceSettings.maxRate,
                    divisions: 6,
                    onChanged: (value) => setState(() => _dragRate = value),
                    onChangeEnd: (value) {
                      ref.read(voiceSettingsProvider.notifier).setRate(value);
                      setState(() => _dragRate = null);
                    },
                  ),
                ),
                Text(l10n.voiceRateFast, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                // Disabled while speaking: a second tap does not "hurry it up",
                // it queues another full synthesis.
                onPressed: _testing ? null : _testVoice,
                icon: _testing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(l10n.voiceTestButton),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.translate_outlined,
                    size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.voiceLanguageNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Speaks a neutral-Spanish sample through the SHARED gateway, so the test
  /// uses the exact same Piper-preferred + persisted-rate path the chat does.
  ///
  /// Two guarantees the old fire-and-forget version broke:
  ///  * the spinner is on screen in the SAME frame as the tap (the setState
  ///    happens before the first await), so the tap is never swallowed;
  ///  * the result is reported honestly — including a fallback to the robotic
  ///    system voice, which is NOT the success this screen promises.
  Future<void> _testVoice() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _testing = true); // before any await: same frame as the tap

    VoiceTestOutcome outcome;
    try {
      outcome = await ref.read(textToSpeechGatewayProvider).speakDiagnostic(l10n.voiceSampleText);
    } catch (e) {
      // The contract says implementations do not throw; if one does, that is
      // still a failure we could not attribute — never a silent success.
      outcome = VoiceTestFailed(VoiceTestFailure.unknown, detail: '$e');
    }
    if (!mounted) return;

    setState(() => _testing = false);
    _reportOutcome(outcome);
  }

  /// Turns the outcome into one SnackBar: the plain-language sentence, plus the
  /// recovery the failure itself dictates (never chosen by hand here).
  void _reportOutcome(VoiceTestOutcome outcome) {
    final l10n = AppLocalizations.of(context);

    final (String message, VoiceTestRecovery recovery) = switch (outcome) {
      VoiceTestSpoke(engine: VoiceTestEngine.neural) => (
          l10n.voiceTestSpokeNeural,
          VoiceTestRecovery.none,
        ),
      // The system voice answered. Say so, and say why — the neural download is
      // Wi-Fi-only, so "pending" can last forever without a word.
      VoiceTestSpoke(:final neuralFailure) => (
          neuralFailure == VoiceTestFailure.voiceMissing
              ? l10n.voiceTestSpokeSystemVoiceMissing
              : l10n.voiceTestSpokeSystem,
          neuralFailure?.recovery ?? VoiceTestRecovery.none,
        ),
      VoiceTestFailed(:final failure) => (_failureMessage(failure, l10n), failure.recovery),
    };

    final action = switch (recovery) {
      VoiceTestRecovery.downloadVoice => SnackBarAction(
          label: l10n.voiceDownloadButton,
          onPressed: () => ref
              .read(voiceCatalogControllerProvider.notifier)
              .download(ref.read(selectedVoiceProvider)),
        ),
      VoiceTestRecovery.chooseAnotherVoice => SnackBarAction(
          label: l10n.voiceCatalogNavTitle,
          onPressed: () => context.push('/settings/voice/catalog'),
        ),
      VoiceTestRecovery.retry => SnackBarAction(
          label: l10n.voiceRetryButton,
          onPressed: _testVoice,
        ),
      VoiceTestRecovery.none => null,
    };

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// One sentence per observed cause. Exhaustive on purpose: a new failure must
  /// be given its own words, not folded into a generic "inténtalo de nuevo".
  String _failureMessage(VoiceTestFailure failure, AppLocalizations l10n) => switch (failure) {
        VoiceTestFailure.voiceMissing => l10n.voiceTestFailedVoiceMissing,
        VoiceTestFailure.voiceIncompatible => l10n.voiceTestFailedVoiceIncompatible,
        VoiceTestFailure.synthesisFailed => l10n.voiceTestFailedSynthesis,
        VoiceTestFailure.emptySynthesis => l10n.voiceTestFailedEmpty,
        VoiceTestFailure.playbackFailed => l10n.voiceTestFailedPlayback,
        VoiceTestFailure.noEngine => l10n.voiceTestFailedNoEngine,
        VoiceTestFailure.unknown => l10n.voiceTestFailedUnknown,
      };
}

/// The voice-status card: reflects [TtsVoiceStatus] (absent / downloading /
/// ready / failed) and offers a download / retry action for the two states
/// where the user can act.
class _VoiceStatusCard extends ConsumerWidget {
  const _VoiceStatusCard({required this.status});

  final TtsVoiceStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    final (IconData icon, Color color, String title, String detail) = switch (status) {
      TtsVoiceReady() => (
          Icons.graphic_eq,
          scheme.primary,
          l10n.voiceStatusReady,
          l10n.voiceStatusReadyDetail,
        ),
      TtsVoiceDownloading(:final progress) => (
          Icons.downloading_outlined,
          scheme.primary,
          l10n.voiceStatusDownloading((progress.clamp(0.0, 1.0) * 100).round()),
          l10n.voiceStatusReadyDetail,
        ),
      TtsVoiceFailed() => (
          Icons.error_outline,
          scheme.error,
          l10n.voiceStatusFailed,
          l10n.voiceStatusAbsentDetail,
        ),
      TtsVoiceAbsent() => (
          Icons.speaker_notes_outlined,
          scheme.onSurfaceVariant,
          l10n.voiceStatusAbsent,
          l10n.voiceStatusAbsentDetail,
        ),
    };

    final downloading = status is TtsVoiceDownloading;
    final canDownload = status is TtsVoiceAbsent || status is TtsVoiceFailed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(detail, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          if (downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: switch (status) {
                TtsVoiceDownloading(:final progress) when progress >= 0 =>
                  progress.clamp(0.0, 1.0),
                _ => null,
              },
            ),
          ],
          if (canDownload) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => ref
                    .read(voiceCatalogControllerProvider.notifier)
                    .download(ref.read(selectedVoiceProvider)),
                icon: const Icon(Icons.download_outlined),
                label: Text(
                  status is TtsVoiceFailed ? l10n.voiceRetryButton : l10n.voiceDownloadButton,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
