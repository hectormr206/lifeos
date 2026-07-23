import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_permission.dart';
import 'permission_request_helper.dart';
import 'permissions_onboarding_screen.dart';
import 'permissions_providers.dart';

/// Settings › Permisos (permissions slice).
///
/// Lists every runtime permission with its live status (Concedido / Denegado /
/// Bloqueado) and lets the user change it. Re-checks status on resume (the user
/// often flips a permission in system Settings and comes back). Tapping a
/// non-granted permission runs the shared re-request/blocked helper for
/// notifications, or opens system Settings for the rest.
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from system Settings (where the user may have flipped a
    // permission) → re-read every permission's live status.
    if (state == AppLifecycleState.resumed) _refreshAll();
  }

  void _refreshAll() {
    for (final permission in AppPermission.values) {
      ref.invalidate(permissionStatusProvider(permission));
    }
  }

  Future<void> _onTap(AppPermission permission) async {
    if (permission == AppPermission.notifications) {
      // Re-request-on-use pattern wired for notifications: request if denied,
      // or explain + offer Settings if permanently denied.
      await ensurePermission(context, ref, permission);
    } else {
      // The rest are best changed from system Settings.
      await ref.read(permissionsGatewayProvider).openSettings();
    }
    _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permisos')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              'Estos son los permisos que LifeOS puede usar. Toca uno para '
              'cambiarlo.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          for (final permission in AppPermission.values)
            _PermissionTile(
              permission: permission,
              onTap: () => _onTap(permission),
            ),
        ],
      ),
    );
  }
}

class _PermissionTile extends ConsumerWidget {
  const _PermissionTile({required this.permission, required this.onTap});

  final AppPermission permission;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(permissionStatusProvider(permission));
    final state = async.asData?.value;
    return ListTile(
      leading: Icon(iconForPermission(permission)),
      title: Text(permission.title),
      subtitle: Text(permission.rationale),
      trailing: state == null
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _StatusChip(state: state),
      onTap: onTap,
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final PermissionState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (state) {
      PermissionState.granted => (scheme.primary, Icons.check_circle_outline),
      PermissionState.denied => (scheme.onSurfaceVariant, Icons.remove_circle_outline),
      PermissionState.permanentlyDenied => (scheme.error, Icons.block_outlined),
      PermissionState.unsupported => (scheme.onSurfaceVariant, Icons.help_outline),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(
          permissionStateLabel(state),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}
