import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_palette.dart';
import '../../../theme/lifeos_tokens.dart';
import '../domain/biometric_authenticator.dart';
import 'app_lock_providers.dart';

/// Full-screen lock shown by [AppLockGate] while the app is locked. Covers ALL
/// app content — nothing behind it is revealed until auth succeeds.
///
/// Behaviour:
///  * On mount it triggers ONE authentication attempt (so app entry / re-lock
///    prompts automatically). It does NOT auto-retry on failure — that would
///    loop against a cancelling user; instead the "Desbloquear" button lets the
///    user retry deliberately.
///  * If the device can no longer authenticate at all ([BiometricAuthResult
///    .unavailable]) it shows an explanation plus a "Desactivar bloqueo" escape
///    so the user is never hard locked out of their own on-device data.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  /// The last attempt's outcome (null before the first attempt / while one is
  /// running). Drives the `unavailable` escape branch.
  BiometricAuthResult? _lastResult;
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    // Auto-prompt once after the first frame (context/providers ready).
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    if (_inFlight) return;
    setState(() => _inFlight = true);
    final result = await ref.read(appLockControllerProvider.notifier).authenticate();
    // On success the controller flips the status to `unlocked`, which unmounts
    // this screen — so guard with `mounted` before touching state.
    if (!mounted) return;
    setState(() {
      _lastResult = result;
      _inFlight = false;
    });
  }

  Future<void> _disable() async {
    await ref.read(appLockControllerProvider.notifier).disable();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final unavailable = _lastResult == BiometricAuthResult.unavailable;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  key: const Key('lock-axi-mark'),
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: LifeOSPalette.of(context).axiBubble,
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.antiAlias,
                  padding: const EdgeInsets.all(Space.md),
                  child: Image.asset(
                    'assets/branding/axi-512.png',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => Icon(
                      unavailable ? Icons.lock_outline : Icons.fingerprint,
                      size: 44,
                      color: scheme.secondary,
                    ),
                  ),
                ),
                const SizedBox(height: Space.xl),
                Text(
                  l10n.appLockLockedTitle,
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Space.md),
                Text(
                  unavailable ? l10n.appLockUnavailableBody : l10n.appLockLockedBody,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (unavailable)
                  OutlinedButton.icon(
                    onPressed: _disable,
                    icon: const Icon(Icons.lock_open_outlined),
                    label: Text(l10n.appLockDisableButton),
                  )
                else
                  FilledButton.icon(
                    onPressed: _inFlight ? null : _authenticate,
                    icon: _inFlight
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fingerprint),
                    label: Text(l10n.appLockUnlockButton),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
