// Proves SettingsScreen's schema-driven form: boolean -> Switch, enum ->
// DropdownButton, integer/number -> validated TextFormField (client-side
// bounds), string -> TextFormField; the save action posts only the fields
// the user actually edited. No live engine — repository faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/settings/data/settings_repository.dart';
import 'package:lifeos/features/settings/domain/config_field_descriptor.dart';
import 'package:lifeos/features/settings/presentation/settings_notifier.dart';
import 'package:lifeos/features/settings/presentation/settings_screen.dart';

class _FakeSettingsRepository implements SettingsRepository {
  _FakeSettingsRepository({this.fields = const [], this.fetchError});

  final List<ConfigFieldDescriptor> fields;
  final SettingsException? fetchError;
  Map<String, Object?>? lastChanges;
  int updateCalls = 0;

  @override
  Future<List<ConfigFieldDescriptor>> fetchConfig() async {
    if (fetchError != null) throw fetchError!;
    return fields;
  }

  @override
  Future<List<ConfigFieldDescriptor>> updateConfig(Map<String, Object?> changes) async {
    updateCalls++;
    lastChanges = changes;
    return fields;
  }
}

const _boolField = ConfigFieldDescriptor(
  name: 'tts_enabled',
  type: ConfigValueType.boolean,
  value: true,
  description: 'Habla las respuestas.',
);

const _enumField = ConfigFieldDescriptor(
  name: 'language',
  type: ConfigValueType.string,
  value: 'es',
  enumValues: ['es-MX', 'es', 'en'],
);

const _intField = ConfigFieldDescriptor(
  name: 'meeting_window_minutes',
  type: ConfigValueType.integer,
  value: 15,
  minimum: 1,
  maximum: 120,
);

const _stringField = ConfigFieldDescriptor(name: 'user_name', type: ConfigValueType.string, value: 'Héctor');

void main() {
  testWidgets('a boolean field renders a Switch', (tester) async {
    final repo = _FakeSettingsRepository(fields: const [_boolField]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('tts_enabled'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.value, isTrue);
  });

  testWidgets('an enum field renders a DropdownButton with the current value selected', (tester) async {
    final repo = _FakeSettingsRepository(fields: const [_enumField]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(DropdownButton<String>), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    expect(dropdown.value, 'es');
  });

  testWidgets('an integer field renders a TextFormField', (tester) async {
    final repo = _FakeSettingsRepository(fields: const [_intField]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
  });

  testWidgets('a string field renders a TextFormField with the current value', (tester) async {
    final repo = _FakeSettingsRepository(fields: const [_stringField]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Héctor'), findsOneWidget);
  });

  testWidgets('an out-of-range integer shows a client-side validation error and blocks save', (tester) async {
    final repo = _FakeSettingsRepository(fields: const [_intField]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), '999');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('120'), findsOneWidget);
    expect(repo.updateCalls, 0);
  });

  testWidgets('saving only POSTs the field the user actually changed', (tester) async {
    final repo = _FakeSettingsRepository(fields: const [_boolField, _stringField]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pump();
    await tester.pump();

    expect(repo.updateCalls, 1);
    expect(repo.lastChanges, {'tts_enabled': false});
  });

  testWidgets('shows an error state with a retry button on load failure', (tester) async {
    final repo = _FakeSettingsRepository(fetchError: SettingsException('boom'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });
}
