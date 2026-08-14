// The home screen and the settings hub must not offer a single destination
// that only works when this device is paired to a remote engine.
//
// WHY THIS IS A SOURCE CONTRACT, not a widget test. The engine-only buttons
// render perfectly on an unpaired device — they look identical to the working
// ones. What is wrong is not how they draw, it is that tapping them redirects
// to `/settings/connection` (the pairing gate in `lib/app.dart`), so the whole
// screen is a promise the device cannot keep. A widget test would have to
// assert the ABSENCE of six specific labels, which silently passes the day a
// label is renamed. Reading the navigation calls out of the source cannot.
//
// WHAT WAS WRONG. LifeOS is autonomous on every device; pairing is a SYNC
// relationship, never a licence server. Home nevertheless led with six
// engine-only surfaces — "Cómo está Axi" (`/body`), "El cerebro de Axi"
// (`/graph`), "Reuniones" (`/meetings`), "Resumen" (`/insights`), "Boletines"
// (`/briefings`) and "Resumen de hoy" (`/digest`) — plus the engine config
// editor in settings. On a phone that has never been paired, every one of them
// bounced to the pairing screen.
//
// Two of them had a WORKING on-device twin buried in settings: the local
// morning briefing at `/settings/briefing` and the local daily digest at
// `/settings/daily-digest`. So the autonomous feature was undiscoverable and
// the blocked one was prominent — the exact shape of the "Cerebro" defect,
// where the on-device 3D graph was reachable only by tapping an unlabelled
// region of the mascot's forehead while the plain label pointed at the gated
// engine browser.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Routes that CANNOT work without a live paired engine, mapped to what a
/// device is supposed to offer instead. `null` means "nothing — the capability
/// genuinely lives on the other machine".
const Map<String, String?> _engineOnlyRoutes = {
  '/body': null, // the ENGINE's own process/service health
  '/insights': null, // GET /api/v1/insights/preview
  '/briefings': '/settings/briefing', // local twin: MorningBriefingScreen
  '/digest': '/settings/daily-digest', // local twin: DailyDigestScreen
  '/graph': null, // engine knowledge-graph search (≠ on-device /brain3d)
  '/meetings': null, // viewer of recordings the laptop makes
  '/settings/engine': null, // configures the remote engine itself
};

/// Files whose job is to offer the user somewhere to go.
const List<String> _navigationSurfaces = [
  'lib/features/home/presentation/home_screen.dart',
  'lib/features/settings/presentation/settings_hub_screen.dart',
];

void main() {
  for (final path in _navigationSurfaces) {
    test('$path offers no engine-only destination', () {
      final source = File(path).readAsStringSync();

      final offenders = <String>[];
      for (final route in _engineOnlyRoutes.keys) {
        // Exact-argument match: `push('/graph')` must not also catch
        // `push('/settings/graph')`, which is a local, ungated screen.
        final navigates = RegExp("(push|go|pushReplacement)\\(\\s*'${RegExp.escape(route)}'\\s*[,)]");
        if (navigates.hasMatch(source)) {
          final replacement = _engineOnlyRoutes[route];
          offenders.add(
            replacement == null
                ? "$route (remove it — it needs the other machine)"
                : "$route (point it at $replacement, the on-device twin)",
          );
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'These destinations bounce an unpaired device straight to the '
            'pairing screen, so they are dead buttons on a device that is '
            'meant to be autonomous:\n  ${offenders.join('\n  ')}',
      );
    });
  }

  test('the on-device twins the home screen now points at really exist', () {
    // Guards the other half of the change: it is no use banning `/briefings`
    // if the replacement route was a typo. These two are ungated in
    // `lib/app.dart` — no `needsPairing` entry — and back local features.
    final router = File('lib/app.dart').readAsStringSync();

    for (final local in ['/settings/briefing', '/settings/daily-digest']) {
      expect(
        router.contains("path: '$local'"),
        isTrue,
        reason: '$local is offered on the home screen but is not a route',
      );
    }
    expect(router.contains('MorningBriefingScreen'), isTrue);
    expect(router.contains('DailyDigestScreen'), isTrue);
  });

  test('the contract can still fail — it is not matching a stale pattern', () {
    // A regex that quietly stopped matching would report a clean file forever,
    // which is how this defect survived a full green suite in the first place.
    const reintroduced = "onPressed: () => context.push('/briefings'),";
    final navigates = RegExp("(push|go|pushReplacement)\\(\\s*'/briefings'\\s*[,)]");

    expect(navigates.hasMatch(reintroduced), isTrue);
    // ...and the near-miss it must NOT catch.
    final graph = RegExp("(push|go|pushReplacement)\\(\\s*'/graph'\\s*[,)]");
    expect(graph.hasMatch("context.push('/settings/graph')"), isFalse);
  });
}
