import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/graph/graph_providers.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/brain3d_payload.dart';

/// The Cerebro 3D payload built from the ON-DEVICE graph (read side only).
/// A plain FutureProvider — recomputed on each screen entry via `ref.refresh`
/// is unnecessary: autoDispose drops it when the screen closes so the next
/// visit re-reads the (possibly grown) local graph.
final brain3dPayloadProvider = FutureProvider.autoDispose<Brain3dPayload>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return buildBrain3dPayload(store);
});

/// Cerebro 3D — mobile parity of the laptop's /brain3d: an interactive
/// force-directed 3D rendering of the user's LOCAL memory graph so "Axi está
/// relacionando todo lo que le cuentas" is visible on the phone too.
///
/// Rendering reuses the laptop's vendored 3d-force-graph bundle (three.js
/// included) inside an offline WebView (assets/brain3d/*, no CDN); the graph
/// data is injected as JSON via `axiLoadGraph(...)` once the page loads.
/// Node taps open the in-page info panel; orbit/pinch come from the lib's
/// native touch controls. Platforms without a WebView implementation (host
/// tests, Linux) get a textual summary fallback instead.
class Brain3dScreen extends ConsumerStatefulWidget {
  const Brain3dScreen({super.key});

  @override
  ConsumerState<Brain3dScreen> createState() => _Brain3dScreenState();
}

class _Brain3dScreenState extends ConsumerState<Brain3dScreen> {
  WebViewController? _controller;
  bool _pageReady = false;
  bool _graphSent = false;

  @override
  void initState() {
    super.initState();
    if (WebViewPlatform.instance != null) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF0B0E13))
        ..addJavaScriptChannel('Brain3d', onMessageReceived: (_) {
          // Node-tap events; the info panel itself is in-page. Reserved for
          // future navigation into the node detail screen.
        })
        ..setNavigationDelegate(
          NavigationDelegate(onPageFinished: (_) {
            _pageReady = true;
            _maybeSendGraph();
          }),
        )
        ..loadFlutterAsset('assets/brain3d/brain3d.html');
    }
  }

  /// Injects the payload once BOTH the page and the data are ready, in
  /// whichever order they arrive. Double-encoding keeps the JSON safe as a
  /// JS string literal (quotes, U+2028/9) and re-parses it in-page.
  void _maybeSendGraph() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null || !_pageReady || _graphSent) return;
    final payload = ref.read(brain3dPayloadProvider).value;
    if (payload == null) return;
    _graphSent = true;
    final json = jsonEncode(jsonEncode(payload.toJson()));
    final lang = jsonEncode(Localizations.localeOf(context).languageCode);
    controller.runJavaScript('axiLoadGraph(JSON.parse($json), $lang)');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final payload = ref.watch(brain3dPayloadProvider);

    // Data may resolve after onPageFinished — try again on every rebuild.
    if (payload.hasValue) _maybeSendGraph();

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E13),
      appBar: AppBar(title: Text(l10n.brain3dTitle)),
      body: switch ((payload, _controller)) {
        (AsyncData(), final WebViewController controller?) =>
          WebViewWidget(controller: controller),
        (AsyncData(:final value), null) => _SummaryFallback(payload: value),
        (AsyncError(:final error), _) =>
          Center(child: Text('$error', style: const TextStyle(color: Colors.white70))),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// Textual stand-in when no WebView platform exists (host tests / desktop):
/// proves the payload pipeline works and keeps the route usable everywhere.
class _SummaryFallback extends StatelessWidget {
  const _SummaryFallback({required this.payload});

  final Brain3dPayload payload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Text(
        payload.nodes.isEmpty
            ? l10n.brain3dEmpty
            : l10n.brain3dSummary(payload.nodes.length, payload.edges.length),
        style: const TextStyle(color: Colors.white70),
        textAlign: TextAlign.center,
      ),
    );
  }
}
