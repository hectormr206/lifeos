// The Dart half of the shared merge-decision fixtures.
//
// Reads `shared/sync-test-vectors/merge_cases.json` — the SAME file
// `axi/tests/test_sync_merge_cases.py` reads. Neither suite states the rules
// itself; both are held to one description of them. That is what makes this
// parity rather than coincidence.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/sync/merge.dart';

/// Finds the shared fixture regardless of where the runner starts.
///
/// `flutter test` sets the working directory to `mobile/` for test BODIES, but
/// top-level code in `main()` runs before that and can see the repo root
/// instead. Rather than depending on which, try both — a fixture that loads
/// only under one invocation is a test that passes only sometimes.
File _sharedFixture(String name) {
  const candidates = ['../shared/sync-test-vectors/', 'shared/sync-test-vectors/'];
  for (final dir in candidates) {
    final file = File('$dir$name');
    if (file.existsSync()) return file;
  }
  throw StateError(
    'the shared fixture $name was not found in any of $candidates — the Dart '
    'merge rule cannot be trusted without it',
  );
}

Map<String, dynamic> _loadCases() =>
    jsonDecode(_sharedFixture('merge_cases.json').readAsStringSync())
        as Map<String, dynamic>;

MergeRevision? _revision(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  return MergeRevision(
    lamport: raw['lamport'] as int,
    originNode: raw['origin_node'] as String,
    deleted: raw['deleted_at'] != null,
  );
}

void main() {
  final data = _loadCases();
  final cases = (data['cases'] as List).cast<Map<String, dynamic>>();

  test('the fixture file is the version this implementation understands', () {
    expect(data['format_version'], 1);
    expect(cases.length, greaterThanOrEqualTo(10));
  });

  for (final c in cases) {
    test('shared case: ${c['name']}', () {
      final local = _revision(c['local'] as Map<String, dynamic>?);
      final incoming = _revision(c['incoming'] as Map<String, dynamic>)!;
      final expected = c['expect'] as Map<String, dynamic>;

      final outcome = decideMerge(local: local, incoming: incoming);

      expect(
        outcome.name,
        expected['outcome'],
        reason: '${c['name']}: Dart and Python must reach the identical verdict',
      );

      // Whether the winner ends up deleted follows from the verdict plus the
      // two revisions — asserted here so a Dart implementation that returned
      // the right enum for the wrong reason still fails.
      final winnerDeleted = switch (outcome) {
        MergeOutcome.inserted => incoming.deleted,
        MergeOutcome.updated => incoming.deleted,
        MergeOutcome.rejected => local!.deleted,
      };
      expect(winnerDeleted, expected['deleted'], reason: '${c['name']}: deleted flag');

      expect(
        isConflict(local: local, incoming: incoming),
        expected['conflict'],
        reason: '${c['name']}: conflict recording',
      );
    });
  }

  group('the rule itself, stated directly', () {
    test('delete dominates a higher lamport — the one deviation from LWW', () {
      final tombstone = const MergeRevision(
        lamport: 5,
        originNode: 'aaaa',
        deleted: true,
      );
      final laterEdit = const MergeRevision(
        lamport: 7,
        originNode: 'bbbb',
        deleted: false,
      );

      expect(
        decideMerge(local: tombstone, incoming: laterEdit),
        MergeOutcome.rejected,
        reason: 'a note the user deleted must not come back because another '
            'device edited it afterwards',
      );
    });

    test('the equal-lamport tiebreak is deterministic in both directions', () {
      const a = MergeRevision(lamport: 5, originNode: 'aaaa', deleted: false);
      const z = MergeRevision(lamport: 5, originNode: 'zzzz', deleted: false);

      // Whichever device applies whichever order, the same revision survives.
      expect(decideMerge(local: a, incoming: z), MergeOutcome.updated);
      expect(decideMerge(local: z, incoming: a), MergeOutcome.rejected);
    });

    test('a device overwriting its own row is not a conflict', () {
      const v1 = MergeRevision(lamport: 1, originNode: 'bbbb', deleted: false);
      const v2 = MergeRevision(lamport: 2, originNode: 'bbbb', deleted: false);

      expect(decideMerge(local: v1, incoming: v2), MergeOutcome.updated);
      expect(isConflict(local: v1, incoming: v2), isFalse);
    });
  });
}
