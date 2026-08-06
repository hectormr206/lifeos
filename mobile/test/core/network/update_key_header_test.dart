// Every download from the update source carries the access key.
//
// WHY THIS MATTERS NOW. Only /manifest, /download and /linux/ are gated today.
// /model/, /stt/, /tts/ and /embed/ are open to the internet, and closing them
// is blocked on exactly one thing: a device that omits the header would stop
// downloading models the moment the gate went up. So the header has to ship
// first and propagate to every device, and only then can the server close.
//
// This test is what makes that plan safe to finish. It fails if a gateway is
// added — or edited — without the header, which is the failure that would
// otherwise be discovered as "models stopped downloading" weeks later, on
// someone's phone, after the server change nobody connected to it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/update_source_config.dart';

void main() {
  test('the header name is the one nginx checks', () {
    // Duplicated in ops/ota/ota-root.conf as $http_x_lifeos_update_key. If
    // these ever disagree, every gated download 403s.
    expect(kUpdateAccessKeyHeader, 'X-LifeOS-Update-Key');
  });

  test('EVERY DownloadTask against the update source sends the key', () {
    // Same shape as the requiresWiFi guard next door, and for the same reason:
    // a convention nobody enforces lasts until the next commit.
    final offenders = <String>[];

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      if (!source.contains('DownloadTask(')) continue;
      if (!source.contains('kUpdateAccessKeyHeader')) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty,
        reason: 'these download from the update source without the access '
            'key:\n${offenders.join('\n')}\n'
            'Add headers: {kUpdateAccessKeyHeader: kUpdateAccessKey}. Without '
            'it, this download breaks the day its path is gated.');
  });
}
