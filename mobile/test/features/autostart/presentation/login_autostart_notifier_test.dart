import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/autostart/domain/login_autostart.dart';
import 'package:lifeos/features/autostart/presentation/login_autostart_providers.dart';

/// The Settings toggle's brain.
///
/// Two rules it exists to enforce:
///   * it reports the state that is REALLY on disk, re-read after every
///     change, because the user can delete the file behind our back; and
///   * a failure to write is shown, not swallowed — a switch that flips to ON
///     and does nothing is the exact quiet degradation this repo forbids.
class _FakeAutostart implements LoginAutostart {
  _FakeAutostart({this.enabled = false});

  bool enabled;
  Object? readError;
  Object? writeError;

  /// Simulates a mechanism that accepts the call and changes nothing.
  bool ignoreWrites = false;

  int readCount = 0;

  @override
  Future<bool> isEnabled() async {
    readCount++;
    final error = readError;
    if (error != null) throw error;
    return enabled;
  }

  @override
  Future<void> setEnabled(bool value) async {
    final error = writeError;
    if (error != null) throw error;
    if (ignoreWrites) return;
    enabled = value;
  }
}

ProviderContainer containerWith({
  required String os,
  LoginAutostart? autostart,
}) {
  final container = ProviderContainer(
    overrides: [
      hostOperatingSystemProvider.overrideWithValue(os),
      loginAutostartPortProvider.overrideWithValue(autostart),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('reads the real state on build', () async {
    final fake = _FakeAutostart(enabled: true);
    final container = containerWith(os: 'linux', autostart: fake);

    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    expect(container.read(loginAutostartProvider).enabled, isTrue);
    expect(fake.readCount, 1);
  });

  test('is unsupported — and inert — on a platform with no login', () async {
    final container = containerWith(os: 'android');
    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    final state = container.read(loginAutostartProvider);
    expect(state.supported, isFalse);
    expect(state.enabled, isFalse);
    expect(state.error, isNull);
  });

  test('enabling re-reads the disk rather than trusting the call', () async {
    final fake = _FakeAutostart();
    final container = containerWith(os: 'linux', autostart: fake);
    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    await notifier.setEnabled(true);

    expect(fake.enabled, isTrue);
    expect(container.read(loginAutostartProvider).enabled, isTrue);
    expect(fake.readCount, greaterThan(1),
        reason: 'the state shown must come from disk, not from the request');
  });

  test('a mechanism that accepts and does nothing is caught', () async {
    // Read-back is what turns "it said yes" into "it is true".
    final fake = _FakeAutostart()..ignoreWrites = true;
    final container = containerWith(os: 'linux', autostart: fake);
    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    await notifier.setEnabled(true);

    final state = container.read(loginAutostartProvider);
    expect(state.enabled, isFalse, reason: 'the switch must not lie');
    expect(state.error, isNotNull);
  });

  test('a refused write surfaces its message and leaves the truth showing',
      () async {
    final fake = _FakeAutostart()
      ..writeError =
          const LoginAutostartUnavailableException('read-only home directory');
    final container = containerWith(os: 'linux', autostart: fake);
    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    await notifier.setEnabled(true);

    final state = container.read(loginAutostartProvider);
    expect(state.enabled, isFalse);
    expect(state.error, contains('read-only home directory'));
  });

  test('a failed READ is an error, not a confident "off"', () async {
    final fake = _FakeAutostart()..readError = StateError('cannot stat');
    final container = containerWith(os: 'linux', autostart: fake);
    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    final state = container.read(loginAutostartProvider);
    expect(state.error, isNotNull);
    expect(state.supported, isTrue);
  });

  test('a later success clears the previous error', () async {
    final fake = _FakeAutostart();
    final container = containerWith(os: 'linux', autostart: fake);
    final notifier = container.read(loginAutostartProvider.notifier);
    await notifier.ready;

    fake.writeError = const LoginAutostartUnavailableException('nope');
    await notifier.setEnabled(true);
    expect(container.read(loginAutostartProvider).error, isNotNull);

    fake.writeError = null;
    await notifier.setEnabled(true);
    final state = container.read(loginAutostartProvider);
    expect(state.error, isNull);
    expect(state.enabled, isTrue);
  });

  test('macOS and Windows are designed but not yet wired, and say so',
      () async {
    for (final os in const ['macos', 'windows']) {
      final container = containerWith(os: os);
      final notifier = container.read(loginAutostartProvider.notifier);
      await notifier.ready;
      expect(container.read(loginAutostartProvider).supported, isFalse,
          reason: '$os has no runner in this repo yet');
    }
  });
}
