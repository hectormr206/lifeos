// Proves the domains hub (spec mobile-domain-crud / mobile-app-shell) shows
// a card for each registered domain (health, finance, exercise this slice).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/presentation/domains_hub_screen.dart';

void main() {
  testWidgets('shows a card for each registered domain', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DomainsHubScreen()));

    for (final descriptor in domainDescriptors) {
      expect(find.text(descriptor.title), findsOneWidget);
    }
  });
}
