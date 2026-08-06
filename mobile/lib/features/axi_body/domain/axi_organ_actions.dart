/// Organ -> mobile action map for Axi's animated body (home screen).
///
/// [AxiBodyWidget] hit-tests the tapped organ and this pure table decides
/// what the app does with it, mirroring the laptop dashboard where each
/// organ has an equivalent on the phone:
///
///   brain  -> Cerebro 3D of the LOCAL graph   (laptop: /brain3d modal)
///   memory -> Mi memoria (local graph browser) (laptop: memory popover)
///   heart  -> body/status screen               (laptop: heartbeat popover)
///   lungs  -> body/status screen               (laptop: vitals popover)
///   ears   -> chat (press-and-hold voice)      (laptop: whisper popover)
///   mouth  -> chat (Axi talks back)            (laptop: click-to-speak)
///   eyes   -> chat (photo attach = vision)     (laptop: eye capture)
///
/// Organs with no mobile equivalent yet (hands/feet/smell/mind/immune)
/// resolve to `null` and the UI shows a friendly "próximamente" notice.
library;

/// Route destinations for each organ key the avatar can emit.
/// `null` = no mobile equivalent yet (show the coming-soon notice).
const Map<String, String?> kAxiOrganRoutes = <String, String?>{
  'brain': '/brain3d',
  'memory': '/settings/graph',
  'heart': '/body',
  'lungs': '/body',
  'ears': '/chat',
  'mouth': '/chat',
  'eyes': '/chat',
  'hands': null,
  'feet': null,
  'smell': null,
  'mind': null,
  'immune': null,
};

/// Resolves an organ key to its route, or `null` for coming-soon organs
/// (including unknown keys a future revision might emit).
String? axiOrganRoute(String organKey) => kAxiOrganRoutes[organKey];
