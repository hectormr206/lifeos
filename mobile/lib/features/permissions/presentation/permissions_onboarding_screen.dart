import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/lifeos_theme.dart';
import '../../../core/platform/platform_providers.dart';
import '../domain/app_permission.dart';
import 'permissions_providers.dart';

/// First-launch permissions onboarding (shown once, gated by the
/// `onboarding_permissions_done` flag via [onboardingGateProvider]).
///
/// A friendly, LifeOS-branded screen that explains WHY each permission is
/// needed, then requests them all in sequence when the user taps "Activar
/// permisos". Skippable ("Ahora no") but clearly recommends granting. Either
/// action marks the gate done and routes into the app — the screen never
/// appears again.
class PermissionsOnboardingScreen extends ConsumerStatefulWidget {
  const PermissionsOnboardingScreen({super.key});

  @override
  ConsumerState<PermissionsOnboardingScreen> createState() =>
      _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState
    extends ConsumerState<PermissionsOnboardingScreen> {
  bool _requesting = false;

  /// The permissions this platform actually has — see [permissionsForPlatform].
  /// Onboarding must never ask for a grant that cannot exist here.
  List<AppPermission> get _permissions =>
      permissionsForPlatform(ref.read(hostOperatingSystemProvider));

  Future<void> _grantAll() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final gateway = ref.read(permissionsGatewayProvider);
    try {
      // Request each permission in sequence: the OS shows one dialog at a time,
      // which reads more clearly than a burst. A denial never blocks the flow.
      for (final permission in _permissions) {
        await gateway.request(permission);
      }
    } catch (_) {
      // Never let a permission hiccup trap the user on onboarding.
    }
    await _finish();
  }

  Future<void> _skip() => _finish();

  Future<void> _finish() async {
    await ref.read(onboardingGateProvider.notifier).complete();
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: LifeOSColors.softPink.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(
                      'assets/branding/axi-512.png',
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stack) =>
                          const Icon(Icons.pets, color: LifeOSColors.pink, size: 36),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Permisos de LifeOS',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Para que Axi funcione al máximo, LifeOS necesita algunos '
                    'permisos. Puedes concederlos todos ahora; si prefieres, '
                    'los pediremos más adelante cuando hagan falta.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 24),
                  for (final permission in _permissions)
                    _PermissionRow(permission: permission),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _requesting ? null : _grantAll,
                      child: _requesting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Activar permisos'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _requesting ? null : _skip,
                    child: const Text('Ahora no'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.permission});

  final AppPermission permission;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconFor(permission), color: scheme.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  permission.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  permission.rationale,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon for a permission, kept in the presentation layer (domain stays free of
/// Flutter's `IconData`). Shared with the Settings permissions list.
IconData iconForPermission(AppPermission permission) => _iconFor(permission);

IconData _iconFor(AppPermission permission) => switch (permission) {
      AppPermission.notifications => Icons.notifications_outlined,
      AppPermission.microphone => Icons.mic_none_outlined,
      AppPermission.camera => Icons.photo_camera_outlined,
      AppPermission.photos => Icons.photo_library_outlined,
      AppPermission.installUnknownApps => Icons.system_update_outlined,
    };
