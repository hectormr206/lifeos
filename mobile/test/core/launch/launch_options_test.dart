import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/launch/launch_options.dart';

/// The launch flag exists for one reason: an app that starts itself at login
/// and then throws a window in the user's face has defeated the point of
/// living in the tray. Parsing is pure, so it is asserted here rather than by
/// launching a real window.
void main() {
  _briefingFlag();
  group('LaunchOptions.parse', () {
    test('a bare launch is a normal, visible launch', () {
      expect(LaunchOptions.parse(const []).startHidden, isFalse);
      expect(LaunchOptions.parse(const []), LaunchOptions.visible);
    });

    test('--hidden is the canonical flag', () {
      expect(LaunchOptions.parse(const ['--hidden']).startHidden, isTrue);
    });

    test('the documented aliases mean the same thing', () {
      for (final alias in const ['--start-hidden', '--start-minimized']) {
        expect(
          LaunchOptions.parse([alias]).startHidden,
          isTrue,
          reason: '$alias must be accepted',
        );
      }
    });

    test('the flag is found wherever it sits in the argument list', () {
      expect(
        LaunchOptions.parse(const ['--verbose', '--hidden', 'file.txt'])
            .startHidden,
        isTrue,
      );
    });

    test('unknown arguments are ignored, never fatal', () {
      // The desktop entry carries `%U`, which the desktop environment expands
      // to zero or more URLs. Refusing to start over an argument we do not
      // recognise would turn a cosmetic launcher detail into a dead app.
      expect(
        () => LaunchOptions.parse(const ['%U', 'lifeos://note/1', '-x']),
        returnsNormally,
      );
      expect(
        LaunchOptions.parse(const ['%U', 'lifeos://note/1']).startHidden,
        isFalse,
      );
    });

    test('a lookalike argument does NOT start the app hidden', () {
      // Substring matching here would mean `--hidden-thing` silently hides the
      // window, which the user could never diagnose.
      for (final argument in const [
        'hidden',
        '--hidden-debug',
        '--no-hidden',
        '--HIDDEN',
      ]) {
        expect(
          LaunchOptions.parse([argument]).startHidden,
          isFalse,
          reason: '$argument is not the flag',
        );
      }
    });

    test('the flag constant is the one the autostart entry writes', () {
      // Pins the two halves together: the entry writer and the parser must
      // never drift, because the failure would be a silent visible window at
      // every login.
      expect(LaunchOptions.parse([hiddenLaunchFlag]).startHidden, isTrue);
    });
  });
}

// El boletín en la laptop, con la aplicación cerrada.
//
// `workmanager` sólo cubre Android e iOS, así que en el escritorio nadie
// generaba el boletín salvo que alguien abriera la aplicación. La pieza que
// falta no es el generador — ese ya corre headless — sino una forma de
// pedírselo desde fuera: un temporizador de systemd lanza el mismo binario
// con `--run-briefing`, genera y sale sin abrir ventana.
void _briefingFlag() {
  group('--run-briefing', () {
    test('lo reconoce', () {
      expect(
        LaunchOptions.parse(const ['--run-briefing']).runBriefingAndExit,
        isTrue,
      );
    });

    test('un arranque normal no lo lleva', () {
      expect(LaunchOptions.parse(const []).runBriefingAndExit, isFalse);
    });

    test('no se confunde con --hidden', () {
      final o = LaunchOptions.parse(const ['--hidden']);
      expect(o.runBriefingAndExit, isFalse);
      expect(o.startHidden, isTrue);
    });

    test('un prefijo parecido NO cuenta', () {
      // Aceptar prefijos convertiría un futuro `--run-briefing-debug` en una
      // aplicación que se cierra sola sin que nadie sepa por qué.
      expect(
        LaunchOptions.parse(const ['--run-briefing-later']).runBriefingAndExit,
        isFalse,
      );
    });

    test('generar no implica ventana oculta: son cosas distintas', () {
      // Con este flag el proceso ni siquiera llega a runApp; que startHidden
      // quede en false deja claro que la ventana no entra en la ecuación.
      expect(
        LaunchOptions.parse(const ['--run-briefing']).startHidden,
        isFalse,
      );
    });
  });
}
