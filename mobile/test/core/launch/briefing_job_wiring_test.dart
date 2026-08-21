// Las tres copias del mismo flag tienen que decir lo mismo.
//
// `--run-briefing` aparece en tres sitios que nadie compila juntos: el parser
// de Dart, el runner de GTK (que decide no mostrar la ventana antes de que
// Dart exista) y la unidad de systemd que lo invoca. Si uno cambia y los otros
// no, el fallo es silencioso: el boletín deja de generarse, o peor, aparece
// una ventana en la cara del usuario a las seis de la mañana.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/launch/launch_options.dart';

void main() {
  test('el runner de GTK conoce el flag', () {
    final source = File('linux/runner/my_application.cc').readAsStringSync();
    expect(
      source,
      contains('"$runBriefingFlag"'),
      reason: 'sin esto la ventana se muestra antes de que Dart pueda salir',
    );
  });

  test('la unidad de systemd invoca ese mismo flag', () {
    final unit = File('tools/systemd/lifeos-briefing.service');
    expect(unit.existsSync(), isTrue,
        reason: 'ejecuta esto desde el directorio mobile/');
    expect(unit.readAsStringSync(), contains(runBriefingFlag));
  });

  test('la unidad es de usuario, no de sistema', () {
    // Escribe los datos del usuario y necesita su sesión gráfica; como root no
    // tendría ni HOME ni display, y fallaría cada quince minutos para siempre.
    final unit = File('tools/systemd/lifeos-briefing.service').readAsStringSync();
    expect(unit, isNot(contains('WantedBy=multi-user.target')));
    expect(unit, contains('graphical-session.target'));
  });

  test('el temporizador sobrevive a que la laptop esté suspendida', () {
    // Sin Persistent la ejecución de las 6:00 que ocurrió mientras dormía
    // simplemente no pasa — y esa es justo la que importa.
    final timer = File('tools/systemd/lifeos-briefing.timer').readAsStringSync();
    expect(timer, contains('Persistent=true'));
  });

  test('el instalador coloca y habilita las dos unidades', () {
    final installer = File('tools/install-linux.sh').readAsStringSync();
    for (final unit in const [
      'lifeos-briefing.service',
      'lifeos-briefing.timer',
    ]) {
      expect(installer, contains(unit));
    }
    expect(installer, contains('systemctl --global enable lifeos-briefing.timer'));
  });

  test('el publicador mete las unidades en el tarball', () {
    // Instalarlas no sirve de nada si no viajan en la release: el instalador
    // avisaría y seguiría, y nadie miraría ese aviso.
    final publisher = File('tools/publish-linux-to-vps.sh').readAsStringSync();
    expect(publisher, contains('lifeos-briefing.service'));
    expect(publisher, contains('lifeos-briefing.timer'));
  });

  test('las unidades las coloca la copia que llegó con la release', () {
    // El actualizador ejecuta el instalador YA INSTALADO, que es el de la
    // versión anterior. Sin delegar, una release que añade una unidad nueva no
    // la colocaría hasta la release siguiente, y nadie podría ver por qué.
    final installer = File('tools/install-linux.sh').readAsStringSync();
    expect(installer, contains('--install-units'));
    expect(installer, contains(r'"$BIN_DIR/lifeos-install.sh" --install-units'));
    expect(installer, contains('install-units) install_units ;;'));
  });

  test('si la copia vieja no conoce el modo, lo hace ella misma', () {
    // Un fallback que no existiera dejaría la máquina sin unidades para
    // siempre en cuanto la delegación fallara por cualquier motivo.
    final installer = File('tools/install-linux.sh').readAsStringSync();
    expect(
      installer,
      contains('--install-units >/dev/null 2>&1; then\n    install_units'),
    );
  });

  test('el temporizador arranca en las sesiones ya abiertas', () {
    // Visto en la laptop del usuario: "enabled" pero "inactive (dead)" y
    // "Trigger: n/a". La unidad estaba colocada y no iba a dispararse nunca,
    // porque sólo se arrancaba cuando alguien tecleaba sudo a mano — y el
    // actualizador automático no teclea nada. En una laptop que no se apaga,
    // "arrancará en el próximo login" significa "quizá la semana que viene".
    final installer = File('tools/install-linux.sh').readAsStringSync();
    expect(installer, contains('/run/user/*/bus'));
    expect(installer, contains('systemctl --user enable --now lifeos-briefing.timer'));
    expect(
      installer,
      isNot(contains(r'if [ -n "${SUDO_USER:-}" ]')),
      reason: 'depender de SUDO_USER es justo lo que dejó el timer muerto',
    );
  });

  test('desinstalar se lleva las unidades del usuario', () {
    final installer = File('tools/install-linux.sh').readAsStringSync();
    expect(installer, contains(r'$USER_UNIT_DIR/lifeos-briefing.service'));
    expect(installer, contains('systemctl --global disable lifeos-briefing.timer'));
  });
}
