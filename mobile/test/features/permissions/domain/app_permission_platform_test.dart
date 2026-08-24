// Proves the permission LIST is platform-honest.
//
// "Instalar apps" is Android's REQUEST_INSTALL_PACKAGES — it exists so the OTA
// updater can install a downloaded APK. On Linux the updater is the
// `lifeos-updater` systemd timer + service that `tools/install-linux.sh`
// installs; there is no APK, no sideload, and nothing for the user to grant.
// Offering the row there would ask him to approve something that cannot happen.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';

void main() {
  group('permissionsForPlatform', () {
    test('Android offers cada permiso de bienvenida, en orden', () {
      // The Pixel build must not lose a single row. La lista se escribe
      // completa a propósito: si alguien añade un permiso al catálogo, esta
      // prueba le obliga a decidir si va en la bienvenida o no.
      expect(permissionsForPlatform('android'), [
        AppPermission.notifications,
        AppPermission.microphone,
        AppPermission.camera,
        AppPermission.photos,
        AppPermission.installUnknownApps,
      ]);
    });

    test('la exención de batería NO se pide en la bienvenida', () {
      // Se concede desde la pantalla del boletín, con el motivo delante:
      // nadie debería decidir sobre la batería en su primer minuto con la app.
      expect(
        permissionsForPlatform('android'),
        isNot(contains(AppPermission.batteryUnrestricted)),
      );
    });

    test('Linux drops "Instalar apps" and keeps the rest in order', () {
      expect(
        permissionsForPlatform('linux'),
        [
          AppPermission.notifications,
          AppPermission.microphone,
          AppPermission.camera,
          AppPermission.photos,
        ],
      );
      expect(
        permissionsForPlatform('linux'),
        isNot(contains(AppPermission.installUnknownApps)),
      );
    });

    test('the other desktop shells behave like Linux', () {
      for (final os in ['macos', 'windows']) {
        expect(
          permissionsForPlatform(os),
          isNot(contains(AppPermission.installUnknownApps)),
          reason: '$os does not install an APK',
        );
      }
    });

    test('iOS also has no sideloaded-APK concept', () {
      expect(
        permissionsForPlatform('ios'),
        isNot(contains(AppPermission.installUnknownApps)),
      );
    });

    test('an unknown platform is not assumed to sideload', () {
      expect(
        permissionsForPlatform('something-new'),
        isNot(contains(AppPermission.installUnknownApps)),
      );
    });

    test('every returned permission still has a title and a rationale', () {
      // Guards the filter against returning a value the UI cannot render.
      for (final os in ['android', 'linux']) {
        for (final permission in permissionsForPlatform(os)) {
          expect(permission.title, isNotEmpty, reason: '$os / $permission');
          expect(permission.rationale, isNotEmpty, reason: '$os / $permission');
        }
      }
    });
  });
}
