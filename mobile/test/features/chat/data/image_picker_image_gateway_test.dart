// Proves the downscale contract of ImagePickerImageGateway: incoming photos are
// bounded to a ~1024px longest side (maxWidth AND maxHeight) at quality 85. The
// bound is encoder-friendly for gemma-4-E2B's vision tower and cuts per-image
// variance that pushes borderline high-res photos into sampler degeneration.
//
// The gateway delegates straight to the real image_picker plugin (no injection
// seam for the resize params — they are passed to `pickImage`), so we assert the
// contract at the source, matching the source-assertion pattern used elsewhere
// in this codebase (see flutter_gemma_llm_engine_test.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/features/chat/data/image_picker_image_gateway.dart',
  ).readAsStringSync();

  final call = RegExp(r'_picker\.pickImage\(([\s\S]*?)\);').firstMatch(source)?.group(1);

  test('pickImage bounds the longest side to 1024 on BOTH axes', () {
    expect(call, isNotNull);
    expect(call, contains('maxWidth: 1024'));
    expect(call, contains('maxHeight: 1024'),
        reason: 'a portrait photo needs maxHeight too, or its long side stays huge');
  });

  test('pickImage keeps quality 85 to hold the payload small', () {
    expect(call, contains('imageQuality: 85'));
  });
}
