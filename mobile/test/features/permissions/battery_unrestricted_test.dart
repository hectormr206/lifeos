// Que el sistema deje de posponer el boletín.
//
// Medido en el Pixel de pruebas el 2026-08-24: Android tenía LifeOS en el
// bucket de reposo RARE (40) y sin exención de batería, y la tarea del boletín
// arrancó diez minutos tarde. En ese estado el sistema puede posponerla horas:
// WorkManager promete "en algún momento", nunca "a las 7:00".
//
// Es un permiso que el usuario concede A PROPÓSITO desde la pantalla del
// boletín, con el motivo delante. Por eso NO entra en el onboarding: nadie
// debería tener que decidir sobre la batería en su primer minuto con la app.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/permissions/domain/app_permission.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('mapea al permiso real de Android', () {
    expect(
      AppPermission.batteryUnrestricted.platformPermission,
      Permission.ignoreBatteryOptimizations,
    );
  });

  test('tiene título y motivo propios', () {
    expect(AppPermission.batteryUnrestricted.title, isNotEmpty);
    expect(AppPermission.batteryUnrestricted.rationale, isNotEmpty);
  });

  test('NO aparece en la lista del onboarding, en ninguna plataforma', () {
    for (final os in ['android', 'linux', 'ios', 'macos', 'windows']) {
      expect(
        permissionsForPlatform(os),
        isNot(contains(AppPermission.batteryUnrestricted)),
        reason: 'se pide en su contexto, no en la bienvenida ($os)',
      );
    }
  });

  test('sigue siendo parte del catálogo completo', () {
    expect(AppPermission.values, contains(AppPermission.batteryUnrestricted));
  });
}
