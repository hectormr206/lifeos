// Unit tests for the [Capabilities] domain model.
//
// The JSON fixture below matches design D4 (sdd/mobile-app) verbatim:
//
//   {"api_version":"1","engine_version":"x.y.z",
//    "capabilities":{"chat":{"v":1,"features":[...]},
//    "domains":{"v":1,"list":[...]},"sync":{"v":1,"wire":1},
//    "brain":{"v":1,"class":"remote-big"}}}
//
// D4's versioning rule ("integer `v` per capability object; additive fields
// never bump `v`") is why [CapabilityEntry] keeps every non-`v` field as an
// untyped `extra` map instead of hand-declaring per-domain fields (features,
// list, wire, class, ...): the client must be able to read `v` and degrade
// gracefully per-capability without a schema change every time the engine
// adds a field to one capability's payload.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/capabilities.dart';

void main() {
  group('Capabilities.fromJson', () {
    test('parses a design-D4-shaped payload', () {
      final json = <String, Object?>{
        'api_version': '1',
        'engine_version': '0.4.2',
        'capabilities': {
          'chat': {
            'v': 1,
            'features': ['attachments', 'tts', 'transcribe', 'stream'],
          },
          'domains': {
            'v': 1,
            'list': ['health', 'finance'],
          },
          'sync': {'v': 1, 'wire': 1},
          'brain': {'v': 1, 'class': 'remote-big'},
        },
      };

      final caps = Capabilities.fromJson(json);

      expect(caps.apiVersion, '1');
      expect(caps.engineVersion, '0.4.2');
      expect(caps.capabilities.keys, {'chat', 'domains', 'sync', 'brain'});

      final chat = caps.capabilities['chat']!;
      expect(chat.v, 1);
      expect(chat.extra['features'], ['attachments', 'tts', 'transcribe', 'stream']);

      final brain = caps.capabilities['brain']!;
      expect(brain.v, 1);
      expect(brain.extra['class'], 'remote-big');
    });

    test('degrades per-capability: an unknown/new capability key is preserved, not dropped', () {
      final json = <String, Object?>{
        'api_version': '1',
        'engine_version': '0.4.2',
        'capabilities': {
          'a_future_capability_this_client_predates': {'v': 1, 'shiny': true},
        },
      };

      final caps = Capabilities.fromJson(json);

      expect(caps.capabilities.containsKey('a_future_capability_this_client_predates'), isTrue);
      expect(caps.capabilities['a_future_capability_this_client_predates']!.v, 1);
    });

    test('an empty capabilities map still parses (additive-only contract, D4)', () {
      final json = <String, Object?>{
        'api_version': '1',
        'engine_version': '0.4.2',
        'capabilities': <String, Object?>{},
      };

      final caps = Capabilities.fromJson(json);

      expect(caps.capabilities, isEmpty);
    });
  });
}
