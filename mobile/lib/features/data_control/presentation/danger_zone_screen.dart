import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_notifier.dart';
import '../../daily_digest/presentation/daily_digest_notifier.dart';
import '../../domains/presentation/local_domain_notifier.dart';
import '../../graph/presentation/local_graph_notifier.dart';
import '../../insights/presentation/prediction_providers.dart';
import '../../mi_vida/presentation/mi_vida_notifier.dart';
import '../../morning_briefing/presentation/morning_briefing_notifier.dart';
import '../../reminders/presentation/local_reminders_notifier.dart';
import '../domain/backup_info.dart';
import '../domain/wipe_confirm_gate.dart';
import 'data_control_providers.dart';

/// "Zona de peligro → Borrar todos mis datos" (data-control kit, part B).
///
/// Layered protection (logic in [WipeConfirmGate], unit-tested):
///  1. this screen explains EXACTLY what is deleted vs kept;
///  2. the user must TYPE the confirmation word (BORRAR / DELETE);
///  3. the final button stays disabled through a 5-second countdown that
///     only starts once the word matches.
/// A "create backup first" checkbox (default ON) snapshots the data as a
/// manual backup right before wiping. The wipe itself runs the
/// [wipeRegistryProvider] inventory — every registered store purges; models
/// and app settings are never touched.
class DangerZoneScreen extends ConsumerStatefulWidget {
  const DangerZoneScreen({super.key});

  @override
  ConsumerState<DangerZoneScreen> createState() => _DangerZoneScreenState();
}

class _DangerZoneScreenState extends ConsumerState<DangerZoneScreen> {
  final _confirmController = TextEditingController();
  bool _backupFirst = true;
  bool _wiping = false;

  /// Seconds left before the final button arms; null while the typed word
  /// does not match (countdown not started).
  int? _countdown;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _confirmController.addListener(_onTypedChanged);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _confirmController.dispose();
    super.dispose();
  }

  String get _languageCode => Localizations.localeOf(context).languageCode;

  void _onTypedChanged() {
    final matches = WipeConfirmGate.matches(
      _confirmController.text,
      _languageCode,
    );
    if (matches && _countdown == null) {
      // Word just matched → start the countdown; the button arms at 0.
      setState(() => _countdown = WipeConfirmGate.countdownSeconds);
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() {
          final next = (_countdown ?? 1) - 1;
          _countdown = next;
          if (next <= 0) timer.cancel();
        });
      });
    } else if (!matches && _countdown != null) {
      // Word edited away → disarm completely.
      _countdownTimer?.cancel();
      setState(() => _countdown = null);
    }
  }

  bool get _armed => _countdown == 0 && !_wiping;

  Future<void> _wipe() async {
    final l10n = AppLocalizations.of(context);
    if (isDataControlBusy(ref)) {
      _snack(l10n.dataControlBusy);
      return;
    }
    setState(() => _wiping = true);
    try {
      if (_backupFirst) {
        await ref
            .read(graphBackupServiceProvider)
            .createBackup(kind: BackupKind.manual);
      }
      final outcome = await ref.read(wipeRegistryProvider).wipeAll();
      // Reset the in-memory surfaces that mirrored the wiped stores so every
      // graph-backed view refreshes to empty WITHOUT an app restart. These are
      // keep-alive providers that `ref.read` (not `watch`) the store, so they
      // hold stale records until explicitly invalidated.
      ref.invalidate(chatNotifierProvider);
      ref.invalidate(morningBriefingNotifierProvider);
      ref.invalidate(backupsListProvider);
      ref.invalidate(localGraphListProvider); // "Mi memoria" browser
      ref.invalidate(miVidaNotifierProvider); // "Mi vida" aggregation
      ref.invalidate(localDomainNotifierProvider); // per-domain local lists
      ref.invalidate(predictionPatternsProvider); // "Patrones" insights
      ref.invalidate(dailyDigestNotifierProvider); // "Resumen del día" card
      ref.invalidate(localRemindersNotifierProvider); // reminders list
      // Cerebro 3D (brain3dPayloadProvider) is autoDispose and re-reads the
      // store on each screen entry, so it needs no explicit invalidation here.
      if (!mounted) return;
      if (outcome.allSucceeded) {
        _snack(l10n.wipeDone);
        Navigator.of(context).pop();
      } else {
        _snack(l10n.wipePartialFailure(outcome.failures.keys.join(', ')));
      }
    } catch (error) {
      if (mounted) _snack(l10n.backupsOperationFailed('$error'));
    } finally {
      if (mounted) setState(() => _wiping = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final word = WipeConfirmGate.requiredWordFor(_languageCode);
    final countdown = _countdown;

    final buttonLabel = _wiping
        ? l10n.wipeInProgress
        : (countdown != null && countdown > 0)
        ? l10n.wipeCountdownButton(countdown)
        : l10n.wipeConfirmButton;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.wipeTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _InfoCard(
            color: scheme.errorContainer,
            onColor: scheme.onErrorContainer,
            icon: Icons.delete_forever_outlined,
            title: l10n.wipeDeletesTitle,
            body: l10n.wipeDeletesBody,
          ),
          const SizedBox(height: 12),
          _InfoCard(
            color: scheme.secondaryContainer,
            onColor: scheme.onSecondaryContainer,
            icon: Icons.shield_outlined,
            title: l10n.wipeKeepsTitle,
            body: l10n.wipeKeepsBody,
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _backupFirst,
            onChanged: _wiping
                ? null
                : (value) => setState(() => _backupFirst = value ?? true),
            title: Text(l10n.wipeBackupFirst),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            enabled: !_wiping,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.wipeTypePrompt(word),
              hintText: word,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              disabledBackgroundColor: scheme.error.withValues(alpha: 0.25),
            ),
            onPressed: _armed ? _wipe : null,
            icon: _wiping
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_forever),
            label: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.color,
    required this.onColor,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color color;
  final Color onColor;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: onColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(color: onColor, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(color: onColor, height: 1.4)),
        ],
      ),
    );
  }
}
