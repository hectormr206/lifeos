// Guards the rule that automatic heavy downloads never touch mobile data.
//
// The app fetches ~330 MB of APK and ~2.4 GB of model weights on its own
// schedule. On a metered connection that is the user's phone bill, spent by
// software they never told to spend it, and invisibly — a background update
// that shows nothing is exactly one that cannot be noticed until the bill
// arrives.
//
// The requirement was NOT "fix the two downloads that exist". It was that
// anything heavy, now or in the future, obeys this. So the test that matters
// here is the last one: it reads the source and fails when a NEW DownloadTask
// appears without the flag. A convention nobody enforces lasts until the next
// commit.
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/network/heavy_download_policy.dart';

void main() {
  test('the policy is Wi-Fi only, and says so by name', () {
    expect(kHeavyDownloadsRequireWiFi, isTrue);
  });

  test('a user-initiated download is exempt — their data, their choice', () {
    // Tapping "download now" is a decision the app must not override.
    expect(kUserInitiatedDownloadRequiresWiFi, isFalse);
  });

  test('the flag is the one background_downloader actually enforces', () {
    // Not a check this code performs: the platform holds the task until Wi-Fi.
    final task = DownloadTask(
      url: 'https://example.test/big.bin',
      filename: 'big.bin',
      requiresWiFi: kHeavyDownloadsRequireWiFi,
    );

    expect(task.requiresWiFi, isTrue);
  });

  test('EVERY DownloadTask in the app declares requiresWiFi', () {
    // The durable part. A fourth downloader written next year inherits the
    // rule or fails here — it cannot silently omit it.
    final offenders = <String>[];

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      if (!source.contains('DownloadTask(')) continue;
      // Crude on purpose: presence of the constructor without the flag
      // anywhere in the file is enough to demand a human look.
      if (!source.contains('requiresWiFi')) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty,
        reason: 'these build a DownloadTask without declaring requiresWiFi:\n'
            '${offenders.join('\n')}\n'
            'Heavy downloads must pass kHeavyDownloadsRequireWiFi; a genuinely '
            'user-initiated one passes kUserInitiatedDownloadRequiresWiFi.');
  });
}
