import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_permission.dart';
import 'permissions_providers.dart';

/// Re-request-on-use pattern for runtime permissions.
///
/// A feature calls [ensurePermission] at the moment it actually needs a
/// permission (e.g. before recording, before opening the camera). Flow:
///  1. Already granted (or unsupported → don't block) → returns `true`.
///  2. Soft-denied → re-requests (the OS shows its dialog).
///  3. Permanently denied (either up front or after the re-request) → shows a
///     neutral-Spanish dialog explaining the feature can't run and offers a
///     button to open system Settings. Returns `false`.
///
/// Reusable seam. Currently wired for the notification permission from the
/// Settings permissions screen. Feature call sites to add in their own slices:
///   TODO(mic): call `ensurePermission(context, ref, AppPermission.microphone)`
///     from the voice-note recorder before starting a recording.
///   TODO(camera): call `ensurePermission(context, ref, AppPermission.camera)`
///     from the camera capture flow before opening the camera.
Future<bool> ensurePermission(
  BuildContext context,
  WidgetRef ref,
  AppPermission permission,
) async {
  final gateway = ref.read(permissionsGatewayProvider);

  var state = await gateway.status(permission);
  if (state == PermissionState.granted || state == PermissionState.unsupported) {
    return true;
  }

  // Soft denial → re-request (the OS re-prompts).
  if (state == PermissionState.denied) {
    state = await gateway.request(permission);
    if (state == PermissionState.granted || state == PermissionState.unsupported) {
      return true;
    }
  }

  // Denied again / permanently denied — explain and offer Settings.
  if (state == PermissionState.permanentlyDenied) {
    if (!context.mounted) return false;
    await _showBlockedDialog(context, ref, permission);
  }
  return false;
}

Future<void> _showBlockedDialog(
  BuildContext context,
  WidgetRef ref,
  AppPermission permission,
) async {
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Permiso de ${permission.title.toLowerCase()} bloqueado'),
      content: Text(
        'Esta función no puede funcionar sin el permiso de '
        '${permission.title.toLowerCase()}. ${permission.rationale}\n\n'
        'Para activarlo, abre los ajustes del sistema y concede el permiso.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Ahora no'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Abrir ajustes'),
        ),
      ],
    ),
  );
  if (open ?? false) {
    await ref.read(permissionsGatewayProvider).openSettings();
  }
}
