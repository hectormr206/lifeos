import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/axi_organ_actions.dart';

/// Axi's animated body on the home screen — the laptop dashboard's living
/// avatar, ported faithfully: the SAME SVG + CSS keyframes run inside an
/// offline WebView backed by a bundled asset (assets/axi/axi_avatar.html).
///
/// Organ taps arrive through the `Axi` JavaScript channel and are resolved
/// by [kAxiOrganRoutes]; organs without a mobile equivalent yet show a
/// localized "próximamente" snackbar.
///
/// On platforms without a WebView implementation (host widget tests, Linux
/// desktop) it degrades to a static branding image so the home screen never
/// breaks — [WebViewPlatform.instance] is only set by the Android/iOS
/// plugin registrars.
class AxiBodyWidget extends StatefulWidget {
  const AxiBodyWidget({super.key});

  /// Avatar viewport height; matches the SVG's 220x275 intrinsic size.
  static const double height = 285;

  @override
  State<AxiBodyWidget> createState() => _AxiBodyWidgetState();
}

class _AxiBodyWidgetState extends State<AxiBodyWidget> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (WebViewPlatform.instance != null) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..addJavaScriptChannel(
          'Axi',
          onMessageReceived: (message) => _onOrganTap(message.message),
        )
        ..loadFlutterAsset('assets/axi/axi_avatar.html');
    }
  }

  void _onOrganTap(String organKey) {
    if (!mounted) return;
    final route = axiOrganRoute(organKey);
    if (route != null) {
      context.push(route);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).axiOrganComingSoon)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      label: l10n.axiAvatarLabel,
      child: SizedBox(
        height: AxiBodyWidget.height,
        child: _controller != null
            ? WebViewWidget(controller: _controller!)
            // Fallback (tests / platforms without WebView): the static mark.
            : Center(
                child: Image.asset(
                  'assets/branding/axi-512.png',
                  height: 180,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.pets, size: 96, color: Color(0xFFFE8FAF)),
                ),
              ),
      ),
    );
  }
}
