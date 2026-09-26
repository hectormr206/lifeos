// The voice activity model ships inside the app, on every device.
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';

void main() {
  test('the Silero VAD model is bundled, and it is the one that was measured',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final bytes = await rootBundle.load(kVadModelAsset);
    final digest = sha256.convert(bytes.buffer.asUint8List());

    // The file measured on a real 13-minute recording (see NOTICE.md).
    expect(digest.toString(),
        'c36d490aff5ab924ca6c7aeec4d8f6bd3d22db6fa17611b9c5b17eae58ac3a20');
  });
}
