// Proves the organ -> mobile action map behind Axi's animated body: every
// organ key the avatar asset can emit resolves to the intended route (brain
// -> Cerebro 3D, memory -> Mi memoria, heart/lungs -> estado, senses ->
// chat) and every not-yet-ported organ (plus unknown keys) resolves to null
// so the UI shows the "próximamente" notice instead of crashing or
// mis-navigating.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/axi_body/domain/axi_organ_actions.dart';

void main() {
  group('axiOrganRoute', () {
    test('brain opens the Cerebro 3D of the local graph', () {
      expect(axiOrganRoute('brain'), '/brain3d');
    });

    test('memory opens Mi memoria (local graph browser)', () {
      expect(axiOrganRoute('memory'), '/settings/graph');
    });

    test('heart and lungs open the body/status screen', () {
      expect(axiOrganRoute('heart'), '/body');
      expect(axiOrganRoute('lungs'), '/body');
    });

    test('senses (ears, mouth, eyes) open the chat (voice + camera live there)', () {
      expect(axiOrganRoute('ears'), '/chat');
      expect(axiOrganRoute('mouth'), '/chat');
      expect(axiOrganRoute('eyes'), '/chat');
    });

    test('organs without a mobile equivalent yet resolve to null (próximamente)', () {
      for (final key in ['hands', 'feet', 'smell', 'mind', 'immune']) {
        expect(axiOrganRoute(key), isNull, reason: key);
      }
    });

    test('unknown keys from a future asset revision also resolve to null', () {
      expect(axiOrganRoute('tail'), isNull);
    });

    test('every organ key in the avatar asset has an entry in the map', () {
      // Keep in sync with assets/axi/axi_avatar.html tap(...) calls.
      const assetKeys = {
        'ears', 'lungs', 'hands', 'feet', 'immune', 'memory', 'brain',
        'eyes', 'smell', 'mouth', 'heart', 'mind',
      };
      expect(kAxiOrganRoutes.keys.toSet(), assetKeys);
    });
  });
}
