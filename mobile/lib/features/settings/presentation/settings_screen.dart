import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/offline_banner.dart';
import '../../../core/widgets/pending_sync_banner.dart';
import '../domain/config_field_descriptor.dart';
import 'settings_notifier.dart';

/// The engine config editor — mobile parity for the laptop dashboard's
/// `/config` page. Schema-DRIVEN form: each [ConfigFieldDescriptor] renders
/// a widget picked purely from its type (bool -> Switch, enum -> Dropdown,
/// int/number -> validated numeric TextFormField, string -> TextFormField).
/// Only the fields the user actually edits are sent on save, matching the
/// engine's partial-POST contract (`write_config`, dashboard.py:1674).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  /// Edited values keyed by field name, seeded from the loaded descriptors
  /// on first build and on every reload (see [_syncEditsWith]) so unedited
  /// fields always reflect the latest server-known value.
  final Map<String, Object?> _edits = {};

  /// The controllers backing numeric/string TextFormFields, keyed by field
  /// name — kept stable across rebuilds (dispose only what this screen
  /// itself created).
  final Map<String, TextEditingController> _controllers = {};

  List<ConfigFieldDescriptor> _syncedFrom = const [];

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Re-seeds [_edits]/[_controllers] whenever the notifier hands back a
  /// fresh field list (initial load, refresh, or a completed save) — but
  /// only for fields the user hasn't touched since, so an in-flight edit is
  /// never clobbered by a background refresh.
  void _syncEditsWith(List<ConfigFieldDescriptor> fields) {
    if (identical(fields, _syncedFrom)) return;
    _syncedFrom = fields;
    for (final field in fields) {
      _edits.putIfAbsent(field.name, () => field.value);
      if (field.type != ConfigValueType.boolean && !field.isEnum) {
        final controller = _controllers.putIfAbsent(field.name, () => TextEditingController());
        if (controller.text.isEmpty) {
          controller.text = field.value?.toString() ?? '';
        }
      }
    }
  }

  /// Fields whose current [_edits] entry differs from the last-known server
  /// value — exactly what gets POSTed (spec: "only changed fields").
  Map<String, Object?> _computeChanges(List<ConfigFieldDescriptor> fields) {
    final changes = <String, Object?>{};
    for (final field in fields) {
      final edited = _edits[field.name];
      if (edited != field.value) changes[field.name] = edited;
    }
    return changes;
  }

  Future<void> _save(List<ConfigFieldDescriptor> fields) async {
    final formState = _formKey.currentState;
    if (formState != null && !formState.validate()) return;
    final changes = _computeChanges(fields);
    final ok = await ref.read(settingsNotifierProvider.notifier).save(changes);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configuración guardada.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsNotifierProvider);
    _syncEditsWith(state.fields);

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: Column(
        children: [
          const OfflineBanner(),
          const PendingSyncBanner(),
          Expanded(child: _buildBody(state)),
          if (!state.loading && state.error == null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: state.saving ? null : () => _save(state.fields),
                    icon: state.saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                    label: const Text('Guardar'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(SettingsUiState state) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => ref.read(settingsNotifierProvider.notifier).refresh(),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state.fields.isEmpty) {
      return const Center(child: Text('No hay campos de configuración disponibles.'));
    }
    return Form(
      key: _formKey,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: state.fields.length,
        separatorBuilder: (context, index) => const Divider(),
        itemBuilder: (context, index) => _fieldTile(state.fields[index], state),
      ),
    );
  }

  Widget _fieldTile(ConfigFieldDescriptor field, SettingsUiState state) {
    final serverError = state.saveErrorField == field.name ? state.saveError : null;
    if (field.type == ConfigValueType.boolean) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.name),
        subtitle: field.description != null ? Text(field.description!) : null,
        value: (_edits[field.name] as bool?) ?? false,
        onChanged: (value) => setState(() => _edits[field.name] = value),
      );
    }
    if (field.isEnum) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.name),
        subtitle: field.description != null ? Text(field.description!) : null,
        trailing: DropdownButton<String>(
          value: (_edits[field.name] as String?) ?? field.enumValues!.first,
          items: [
            for (final choice in field.enumValues!) DropdownMenuItem(value: choice, child: Text(choice)),
          ],
          onChanged: (value) => setState(() => _edits[field.name] = value),
        ),
      );
    }
    final controller = _controllers[field.name]!;
    final isNumeric = field.type == ConfigValueType.integer || field.type == ConfigValueType.number;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: field.name,
          helperText: field.description,
          errorText: serverError,
          border: const OutlineInputBorder(),
        ),
        keyboardType: isNumeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        onChanged: (text) => setState(() {
          _edits[field.name] = isNumeric ? (num.tryParse(text) ?? text) : text;
        }),
        validator: (_) => field.validate(_edits[field.name]),
      ),
    );
  }
}
