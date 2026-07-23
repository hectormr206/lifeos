// Proves the pure PermissionStatus -> PermissionState mapping and the
// neutral-Spanish status labels. No platform channel: PermissionStatus is a
// plain enum, so its getters resolve in a unit test.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  group('permissionStateFromStatus', () {
    test('granted / limited / provisional map to granted', () {
      expect(permissionStateFromStatus(PermissionStatus.granted), PermissionState.granted);
      expect(permissionStateFromStatus(PermissionStatus.limited), PermissionState.granted);
      expect(permissionStateFromStatus(PermissionStatus.provisional), PermissionState.granted);
    });

    test('permanentlyDenied / restricted map to permanentlyDenied', () {
      expect(
        permissionStateFromStatus(PermissionStatus.permanentlyDenied),
        PermissionState.permanentlyDenied,
      );
      expect(
        permissionStateFromStatus(PermissionStatus.restricted),
        PermissionState.permanentlyDenied,
      );
    });

    test('plain denied maps to denied', () {
      expect(permissionStateFromStatus(PermissionStatus.denied), PermissionState.denied);
    });
  });

  group('permissionStateLabel', () {
    test('maps each state to its neutral-Spanish label', () {
      expect(permissionStateLabel(PermissionState.granted), 'Concedido');
      expect(permissionStateLabel(PermissionState.denied), 'Denegado');
      expect(permissionStateLabel(PermissionState.permanentlyDenied), 'Bloqueado');
      expect(permissionStateLabel(PermissionState.unsupported), 'No disponible');
    });
  });

  group('AppPermission metadata', () {
    test('every permission has a platform mapping, title and rationale', () {
      for (final permission in AppPermission.values) {
        expect(permission.platformPermission, isNotNull);
        expect(permission.title, isNotEmpty);
        expect(permission.rationale, isNotEmpty);
      }
    });
  });
}
