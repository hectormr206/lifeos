// Visual contracts for the chat redesign; all gateways remain headless.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/theme/lifeos_palette.dart';
import 'package:lifeos/theme/lifeos_theme.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';

import '../support/chat_test_harness.dart';
import '../support/fake_chat_gateways.dart';

class _History implements ChatRepository {
  _History(this.messages);
  final List<ChatMessage> messages;
  @override
  Future<List<ChatMessage>> loadHistory() async => messages;
  @override
  Future<ChatMessage> sendMessage(String text) => throw UnimplementedError();
  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) =>
      throw UnimplementedError();
}

Finder _bubbleFor(Finder content) => find.ancestor(
  of: content,
  matching: find.byWidgetPredicate((w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).borderRadius is BorderRadius),
).first;

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  List<ChatMessage> messages = const [],
  FakeAudioRecorderGateway? recorder,
  double? hostWidth,
}) async {
  final baseline = chatApp as MaterialApp;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      chatRepositoryProvider.overrideWithValue(_History(messages)),
      if (recorder != null)
        audioRecorderGatewayProvider.overrideWithValue(recorder),
    ],
    child: MaterialApp(
      theme: dark ? lifeosDarkTheme : lifeosLightTheme,
      locale: baseline.locale,
      localizationsDelegates: baseline.localizationsDelegates,
      supportedLocales: baseline.supportedLocales,
      home: hostWidth == null
          ? baseline.home
          : Center(child: SizedBox(width: hostWidth, child: baseline.home)),
    ),
  ));
  await tester.pumpAndSettle();
}

List<ChatMessage> _messages({bool long = false}) => [
  ChatMessage(
    id: 'user', role: ChatRole.user,
    text: long ? List.filled(80, 'Quiet ink').join(' ') : 'Quiet ink',
    timestamp: DateTime(2026, 7, 22, 10, 30),
  ),
  ChatMessage(
    id: 'axi', role: ChatRole.axi, text: 'Axi speaks',
    timestamp: DateTime(2026, 7, 22, 10, 30),
  ),
];

void main() {
  for (final dark in [false, true]) {
    testWidgets('redesign: ${dark ? 'dark' : 'light'} sender surfaces and body type', (tester) async {
      final theme = dark ? lifeosDarkTheme : lifeosLightTheme;
      final palette = dark ? LifeOSPalette.dark : LifeOSPalette.light;
      await _pump(tester, dark: dark, messages: _messages());
      final user = tester.widget<Container>(_bubbleFor(find.text('Quiet ink')));
      final axi = tester.widget<Container>(_bubbleFor(find.byType(MarkdownBody)));
      final userBox = user.decoration! as BoxDecoration;
      expect(userBox.color, dark
          ? theme.colorScheme.surfaceContainerHigh
          : theme.colorScheme.surfaceContainerLowest);
      expect(userBox.border, dark ? isNull : Border.all(color: palette.hairline));
      expect((axi.decoration! as BoxDecoration).color, palette.axiBubble);
      expect(userBox.borderRadius, const BorderRadius.only(
        topLeft: Radius.circular(Radii.bubble),
        topRight: Radius.circular(Radii.bubble),
        bottomLeft: Radius.circular(Radii.bubble),
        bottomRight: Radius.circular(Radii.bubbleTail),
      ));
      final body = Theme.of(tester.element(find.text('Quiet ink'))).textTheme.bodyLarge;
      expect(tester.widget<Text>(find.text('Quiet ink')).style,
          body?.copyWith(color: theme.colorScheme.onSurface));
      expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).styleSheet?.p,
          body?.copyWith(color: palette.onAxiBubble));
    });
  }

  testWidgets('redesign: bubbles cap at 560 and share a centered 760 column with composer', (tester) async {
    await tester.view.setSize(const Size(1280, 1000));
    await _pump(tester, messages: _messages(long: true));
    final user = _bubbleFor(find.textContaining('Quiet ink'));
    final axi = _bubbleFor(find.byType(MarkdownBody));
    expect(tester.getSize(user).width, lessThanOrEqualTo(560));
    expect(tester.getTopLeft(axi).dx, greaterThanOrEqualTo(260));
    expect(tester.getBottomRight(user).dx, lessThanOrEqualTo(1020));
    final field = tester.getRect(find.byType(TextField));
    expect(field.left, greaterThan(260));
    expect(field.right, lessThan(1020));
  });

  testWidgets('redesign: bubble width follows its narrow host, not the window', (tester) async {
    await tester.view.setSize(const Size(1280, 1000));
    await _pump(tester, hostWidth: 390, messages: _messages(long: true));
    expect(tester.getSize(_bubbleFor(find.textContaining('Quiet ink'))).width,
        lessThanOrEqualTo(390 * .78));
    expect(tester.takeException(), isNull);
  });

  testWidgets('redesign: send is a 48px filled circle, disabled for empty or whitespace text', (tester) async {
    await _pump(tester);
    final send = find.widgetWithIcon(IconButton, Icons.send);
    final button = tester.widget<IconButton>(send);
    expect(button.onPressed, isNull);
    expect(tester.getSize(send), const Size(48, 48));
    expect(button.style?.shape?.resolve({}), const CircleBorder());
    expect(button.style?.backgroundColor?.resolve({}), LifeOSColors.teal);
    expect(button.style?.foregroundColor?.resolve({}), LifeOSColors.dark);
    expect(button.style?.backgroundColor?.resolve({WidgetState.disabled}),
        lifeosLightTheme.colorScheme.onSurface.withValues(alpha: .12));
    await tester.enterText(find.byType(TextField), '  ');
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.filled, isFalse);
    expect(field.decoration?.border, InputBorder.none);
  });

  testWidgets('redesign: recording uses error ink and keeps field, focus and mic mounted', (tester) async {
    await _pump(tester, recorder: FakeAudioRecorderGateway());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final mic = tester.element(find.byIcon(Icons.mic));
    final micRect = tester.getRect(find.byIcon(Icons.mic));
    final gesture = await tester.startGesture(micRect.center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.widget<Icon>(find.byIcon(Icons.fiber_manual_record)).color,
        lifeosLightTheme.colorScheme.error);
    expect(tester.state<EditableTextState>(find.byType(EditableText)), same(editable));
    expect(editable.widget.focusNode.hasFocus, isTrue);
    expect(tester.element(find.byIcon(Icons.mic)), same(mic));
    expect(tester.getRect(find.byIcon(Icons.mic)), micRect);
    expect(find.byType(AbsorbPointer), findsWidgets);
    // Intentional slide cancels, avoiding any STT/platform calls.
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  });
}

extension on TestFlutterView {
  Future<void> setSize(Size size) async {
    physicalSize = size;
    devicePixelRatio = 1;
    addTearDown(resetPhysicalSize);
    addTearDown(resetDevicePixelRatio);
  }
}
