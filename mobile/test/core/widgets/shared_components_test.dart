import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/theme/lifeos_palette.dart';
import 'package:lifeos/theme/lifeos_theme.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget child, {ThemeData? theme}) =>
      tester.pumpWidget(MaterialApp(
        theme: theme ?? lifeosLightTheme,
        home: Scaffold(body: child),
      ));

  testWidgets('PageBody limits readable width and uses a lazy scroll view', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await show(tester, const PageBody(children: [Text('Page content')]));
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.getSize(find.text('Page content')).width, lessThanOrEqualTo(kContentMaxWidth));
    expect(tester.getTopLeft(find.text('Page content')).dx, greaterThan(300));
  });

  testWidgets('PageBody can render a non-scrolling column', (tester) async {
    await show(tester, const PageBody(scrollable: false, children: [Text('Fixed')]));
    expect(find.byType(ListView), findsNothing);
    expect(find.text('Fixed'), findsOneWidget);
  });

  testWidgets('ScrollableCenter can be pulled when content is short', (tester) async {
    var refreshed = false;
    await show(tester, RefreshIndicator(
      onRefresh: () async => refreshed = true,
      child: const ScrollableCenter(child: Text('Short content')),
    ));
    expect(find.text('Short content'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    await tester.drag(find.text('Short content'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(refreshed, isTrue);
  });

  testWidgets('SectionHeader preserves case and announces a header', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, const SectionHeader('Your records'));
    expect(find.text('Your records'), findsOneWidget);
    expect(find.text('YOUR RECORDS'), findsNothing);
    expect(tester.getSemantics(find.text('Your records')), matchesSemantics(
      label: 'Your records', isHeader: true,
    ));
    semantics.dispose();
  });

  testWidgets('GroupedList separates rows with exactly N-1 dividers', (tester) async {
    await show(tester, const GroupedList(children: [
      GroupedRow(title: 'First', icon: Icons.home),
      GroupedRow(title: 'Second'),
      GroupedRow(title: 'Third'),
    ]));
    expect(find.byType(Divider), findsNWidgets(2));
    expect(find.text('Third'), findsOneWidget);
  });

  testWidgets('GroupedRow is a ListTile; tap, subtitle and chevron work', (tester) async {
    var taps = 0;
    await show(tester, GroupedRow(
      title: 'Axi', subtitle: 'Talk to Axi', icon: Icons.chat,
      tone: RowTone.axi, onTap: () => taps++,
    ));
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('Axi'), findsOneWidget);
    expect(find.text('Talk to Axi'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.text('Axi'));
    expect(taps, 1);
  });

  testWidgets('GroupedRow defaults to a two-line subtitle', (tester) async {
    const subtitle = 'First\nSecond\nThird\nFourth';
    await show(tester, const GroupedRow(title: 'Default', subtitle: subtitle));
    final text = tester.widget<Text>(find.text(subtitle));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('GroupedRow can show all four subtitle lines', (tester) async {
    const subtitle = 'First\nSecond\nThird\nFourth';
    await show(tester, const GroupedRow(
      title: 'Unlimited', subtitle: subtitle, subtitleMaxLines: null,
    ));
    final text = tester.widget<Text>(find.text(subtitle));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    final paragraph = tester.renderObject<RenderParagraph>(find.text(subtitle));
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('GroupedRow chevron only appears for actions without trailing', (tester) async {
    await show(tester, Column(children: [
      const GroupedRow(title: 'Static'),
      GroupedRow(title: 'Custom', onTap: () {}, trailing: const Icon(Icons.check)),
    ]));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('disabled GroupedRow does not invoke onTap', (tester) async {
    var taps = 0;
    await show(tester, GroupedRow(title: 'Disabled', enabled: false, onTap: () => taps++));
    await tester.tap(find.text('Disabled'));
    expect(taps, 0);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('EmptyState shows title, message and action', (tester) async {
    await show(tester, EmptyState(
      icon: Icons.inbox, title: 'Nothing yet', message: 'Add your first item',
      action: TextButton(onPressed: () {}, child: const Text('Add item')),
    ));
    expect(find.text('Nothing yet'), findsOneWidget);
    expect(find.text('Add your first item'), findsOneWidget);
    expect(find.text('Add item'), findsOneWidget);
  });

  for (final theme in [lifeosLightTheme, lifeosDarkTheme]) {
    for (final tone in BannerTone.values) {
      testWidgets('StatusBanner $tone uses semantic colors in ${theme.brightness}', (tester) async {
        late Color background;
        late Color foreground;
        await show(tester, Builder(builder: (context) {
          final palette = LifeOSPalette.of(context);
          final scheme = Theme.of(context).colorScheme;
          background = switch (tone) {
            BannerTone.info => palette.infoContainer,
            BannerTone.warning => palette.warningContainer,
            BannerTone.success => palette.successContainer,
            BannerTone.error => scheme.errorContainer,
          };
          foreground = switch (tone) {
            BannerTone.info => palette.onInfoContainer,
            BannerTone.warning => palette.onWarningContainer,
            BannerTone.success => palette.onSuccessContainer,
            BannerTone.error => scheme.onErrorContainer,
          };
          return StatusBanner(tone: tone, icon: Icons.info, message: const Text('Notice'));
        }), theme: theme);
        final decoration = tester.widget<Container>(find.ancestor(
          of: find.text('Notice'), matching: find.byType(Container),
        ).first).decoration as BoxDecoration;
        expect(decoration.color, background);
        expect(tester.widget<Icon>(find.byIcon(Icons.info)).color, foreground);
        expect(DefaultTextStyle.of(tester.element(find.text('Notice'))).style.color, foreground);
      });
    }
  }
}
