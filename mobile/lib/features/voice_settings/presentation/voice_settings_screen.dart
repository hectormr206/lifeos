import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_providers.dart';
import '../../tts/domain/tts_voice.dart';
import '../../tts/presentation/tts_providers.dart';
import '../domain/voice_settings.dart';
import 'voice_settings_providers.dart';

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

  @override
  void initState() {
    super.initState();
    // Proactively make the NEURAL voice the active one: probe + download the
    // Piper voice for the current language on open. No-op if already installed
    // (lands Ready) or a download is already in flight. Fire-and-forget — the
    // status card reflects progress via [ttsVoiceDownloadProvider].
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(ttsVoiceDownloadProvider.notifier).downloadForCurrentLanguage();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final autoSpeak = ref.watch(voiceReplyEnabledProvider);
    final settings = ref.watch(voiceSettingsProvider);
    final voiceStatus = ref.watch(ttsVoiceDownloadProvider);
    final rate = _dragRate ?? settings.rate;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.voiceScreenTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
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
                onPressed: _testVoice,
                icon: const Icon(Icons.play_arrow),
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
  Future<void> _testVoice() async {
    final l10n = AppLocalizations.of(context);
    await ref.read(textToSpeechGatewayProvider).speak(l10n.voiceSampleText);
  }
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
                onPressed: () =>
                    ref.read(ttsVoiceDownloadProvider.notifier).downloadForCurrentLanguage(),
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
