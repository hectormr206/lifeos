// The Dart envelope, held to the same bytes as the Python one.
//
// The strongest assertion here is the CROSS-LANGUAGE one: a payload sealed in
// Dart must open in Python and vice versa. That cannot be checked from inside
// one language, so this suite proves everything it can locally — framing,
// AAD binding, single-use keys — and `axi/tests/test_sync_envelope_parity.py`
// closes the loop by opening a Dart-sealed envelope with the Python code.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/sync/envelope.dart';

List<int> _key(int seed) => List<int>.generate(32, (i) => (i * 7 + seed) & 0xFF);
const String _recipient = '0123456789abcdef0123456789abcdef';

void main() {
  _crossLanguage();
  test('an envelope round-trips', () async {
    final payload = {
      'schema_version': 1,
      'rows': {
        'nodes': [
          {'uuid': 'u-1', 'label': 'desayuno'}
        ],
        'edges': <dynamic>[],
      },
    };

    final blob = await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: payload,
    );
    final opened = await openEnvelope(dataKey: _key(1), blob: blob);

    expect(opened.recipient, _recipient);
    expect(opened.payload, payload);
    expect(opened.envId.length, 64);
  });

  test('the header is the only thing not opaque', () async {
    final blob = await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'secreto': 'hipertensión diagnosticada'},
    );

    expect(blob[0], kEnvelopeVersion);
    expect(
      blob.sublist(33, 49).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      _recipient,
    );

    // The plaintext must not survive anywhere in the sealed bytes.
    final asString = String.fromCharCodes(blob);
    expect(asString.contains('secreto'), isFalse);
    expect(asString.contains('hipertensi'), isFalse);
  });

  test('a wrong key cannot open it', () async {
    final blob = await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'a': 1},
    );

    expect(
      () => openEnvelope(dataKey: _key(2), blob: blob),
      throwsA(isA<SealError>()),
    );
  });

  test('re-addressing an envelope breaks it', () async {
    // The header is AAD. A relay that rerouted an envelope must produce a
    // failure, never a change applied to the wrong graph.
    final blob = Uint8List.fromList(await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'a': 1},
    ));

    blob[40] ^= 0xFF; // flip a bit inside the recipient uuid

    expect(
      () => openEnvelope(dataKey: _key(1), blob: blob),
      throwsA(isA<SealError>()),
    );
  });

  test('tampering with the ciphertext breaks it', () async {
    final blob = Uint8List.fromList(await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'a': 1},
    ));

    blob[blob.length - 20] ^= 0xFF;

    expect(
      () => openEnvelope(dataKey: _key(1), blob: blob),
      throwsA(isA<SealError>()),
    );
  });

  test('two envelopes never share an envelope key', () async {
    // Nonce reuse is impossible by construction, so prove the construction:
    // identical payload, identical key, and the ciphertexts must still differ.
    final a = await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'a': 1},
    );
    final b = await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'a': 1},
    );

    expect(a.sublist(1, 33), isNot(b.sublist(1, 33)), reason: 'shared envId');
    expect(
      a.sublist(kEnvelopeHeaderBytes),
      isNot(b.sublist(kEnvelopeHeaderBytes)),
      reason: 'identical plaintext produced identical ciphertext',
    );
  });

  test('an unsupported version is refused rather than guessed at', () async {
    final blob = Uint8List.fromList(await sealEnvelope(
      dataKey: _key(1),
      recipientUuid: _recipient,
      payload: {'a': 1},
    ));
    blob[0] = 0xFF;

    expect(
      () => openEnvelope(dataKey: _key(1), blob: blob),
      throwsA(isA<SealError>()),
    );
  });
}

/// THE cross-language assertion.
///
/// `shared/sync-test-vectors/envelope_case.json` holds one envelope sealed by
/// PYTHON with a fixed env_id. Two things must hold, and they fail for
/// different reasons:
///
///   * Dart must OPEN it — proves the framing, the AAD binding and the key
///     derivation agree.
///   * Dart must SEAL an envelope Python can open — emitted here as a second
///     committed fixture, because no test inside one language can check that.
///
/// Note what is deliberately NOT asserted: that both produce identical bytes.
/// They do not, and they need not — see the second test for why.
void _crossLanguage() {
  File fixture() {
    for (final dir in const [
      '../shared/sync-test-vectors/',
      'shared/sync-test-vectors/'
    ]) {
      final f = File('${dir}envelope_case.json');
      if (f.existsSync()) return f;
    }
    throw StateError('the shared envelope fixture is missing');
  }

  test('Dart opens an envelope that Python sealed', () async {
    final c = jsonDecode(fixture().readAsStringSync()) as Map<String, dynamic>;

    final opened = await openEnvelope(
      dataKey: _hex(c['data_key'] as String),
      blob: _hex(c['sealed'] as String),
    );

    expect(opened.recipient, c['recipient_uuid']);
    expect(opened.envId, c['env_id']);
    expect(opened.payload, c['payload']);
  });

  test('a Dart-sealed envelope is emitted for Python to open', () async {
    // NOT "Dart seals the identical bytes Python does". That assertion failed,
    // and it was the ASSERTION that was wrong, not the code.
    //
    // The contract is: whatever one side seals, the other must open. It is NOT
    // that both must produce identical bytes — that would force canonical JSON
    // on both languages, which the design deliberately avoided (float
    // formatting and key order are exactly where two JSON encoders drift).
    // Python sorts keys and pads separators; Dart preserves insertion order and
    // pads nothing. Both are valid JSON of the same object, and the AEAD does
    // not care.
    //
    // So this writes Dart's bytes to the shared fixture directory, and
    // `axi/tests/test_sync_envelope_parity.py` opens them. Two committed
    // artifacts, one loop closed in both directions.
    final c = jsonDecode(fixture().readAsStringSync()) as Map<String, dynamic>;

    final blob = await sealEnvelope(
      dataKey: _hex(c['data_key'] as String),
      recipientUuid: c['recipient_uuid'] as String,
      payload: c['payload'] as Map<String, dynamic>,
      envId: _hex(c['env_id'] as String),
    );

    // Dart must at minimum open its own.
    final reopened = await openEnvelope(
      dataKey: _hex(c['data_key'] as String),
      blob: blob,
    );
    expect(reopened.payload, c['payload']);
    expect(reopened.recipient, c['recipient_uuid']);

    final out = File('${fixture().parent.path}/envelope_case_dart.json');
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'format_version': 1,
            'note': 'Sealed by DART with the same fixed inputs as '
                'envelope_case.json. Python opens this in '
                'test_sync_envelope_parity.py. The bytes differ from the Python '
                'fixture because the two JSON encoders order keys and pad '
                'separators differently — that is allowed; opening is the '
                'contract, not byte-identical sealing.',
            'data_key': c['data_key'],
            'env_id': c['env_id'],
            'recipient_uuid': c['recipient_uuid'],
            'payload': c['payload'],
            'sealed': blob.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          })}\n',
    );
  });
}

List<int> _hex(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];
