import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'probe_result.dart';
import 'probe_progress.dart';
import 'probe_scenarios.dart';
import 'probe_storage.dart';
import 'probe_telemetry.dart';

const _candidate = String.fromEnvironment('PROBE_CANDIDATE');
const _appId = 'com.lifeos.lifeos.securityprobe';

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  static bool _claimed = false;
  final _results = <ProbeResult>[];
  bool _running = false;
  String? _artifact;
  String _phase = 'Listo para iniciar';

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<bool> _consume(Stream<ProbeResult> stream) async {
    await for (final result in stream) {
      _results.add(result);
      _refresh();
      if (result.status != ProbeStatus.passed) return false;
      // Yield a frame between scenarios; this does not cancel KDF CPU work.
      await WidgetsBinding.instance.endOfFrame;
    }
    return true;
  }

  Future<void> _run() async {
    if (_claimed || _candidate.trim().isEmpty) return;
    _claimed = true;
    _running = true;
    _phase = 'Ejecutando: no cierre la aplicación';
    _refresh();
    await WidgetsBinding.instance.endOfFrame;
    final started = DateTime.now().toUtc().toIso8601String();
    ProbeProgress? progress;
    try {
      final preflight = await measureProbe('harness_identity', () async {
        await requireProbePackage();
        return null;
      });
      _results.add(preflight);
      if (preflight.status == ProbeStatus.passed) {
        // Identity cannot be recorded before the actual package guard.
        progress = await ProbeProgress.create(
            await getApplicationSupportDirectory(), _candidate);
        await progress.identityVerified(preflight);
        final corePassed = await _consume(runCoreProbe(progress));
        if (corePassed) {
          probeRequire(_results.length == 13 &&
              _results.last.scenarioId == 'kdf_default_roundtrip');
          _phase = 'Ejecutando telemetría sintética';
          _refresh();
          await _consume(runTelemetryProbe(progress));
        }
      }
    } catch (_) {
      _results.add(const ProbeResult(
        'harness_execution', ProbeStatus.failed, 0, ProbeCategory.unexpected,
      ));
    }
    if (progress != null && !progress.failed) {
      try {
        final persisted = await progress.measure('harness_report_write', () async {
          await requireProbePackage();
          final support = await getApplicationSupportDirectory();
          // A new owned directory preserves every previous report, including an
          // interrupted write. It deliberately does not use CORE's fixture prefix.
          final directory = await support.createTemp('probe-report-');
          final name = directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
          final relative = '$name/security-probe-results.json';
          final report = {
            'schema': 'lifeos.security-probe/v1',
            'appId': _appId,
            'candidate': _candidate,
            'candidateEvidence': 'build_injected_claim_pending_apk_binding',
            'startedAtUtc': started,
            'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
            'applicationSupportRelativePath': relative,
            'status': _results.every((r) => r.status == ProbeStatus.passed)
                ? 'passed' : 'stopped',
            'counts': _counts,
            'results': _results.map((r) => r.toJson()).toList(),
            'limits': [
              'synthetic_transport_not_real_network_outage',
              'single_entry_recovery_not_multi_entry_fifo',
              'probe_ui_not_production_banner',
              'apk_source_binding_requires_external_verifier',
            ],
          };
          await File('${directory.path}/security-probe-results.json')
              .writeAsString(jsonEncode(report), flush: true);
          _artifact = relative;
          return null;
        });
        // Persistence success is not an extra security scenario in the artifact.
        if (persisted.status != ProbeStatus.passed) _results.add(persisted);
        await progress.terminal(
            _results.every((r) => r.status == ProbeStatus.passed));
      } catch (_) {
        // A report may exist without confirmed durable journal completion.
        _results.add(const ProbeResult('harness_progress_write',
            ProbeStatus.failed, 0, ProbeCategory.unexpected));
      }
    }
    _running = false;
    _phase = _results.every((r) => r.status == ProbeStatus.passed)
        ? 'Prueba finalizada' : 'Prueba detenida: revise los resultados';
    _refresh();
  }

  Map<String, int> get _counts => {
    for (final status in ProbeStatus.values)
      status.name: _results.where((r) => r.status == status).length,
  };

  @override
  Widget build(BuildContext context) {
    final missingCandidate = _candidate.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Prueba de seguridad aislada')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Solo datos sintéticos. No ejecuta la aplicación LifeOS.'),
          const SizedBox(height: 12),
          Text(missingCandidate
              ? 'Bloqueado: falta PROBE_CANDIDATE en la compilación.'
              : _phase),
          if (!missingCandidate) ...[
            const Text('Identidad declarada al compilar; el controlador debe '
                'vincularla al hash del APK.'),
            Text('Candidato: $_candidate'),
          ],
          const Text('Una ejecución por proceso, sin reintentos. El KDF puede '
              'pausar la interfaz; el límite externo debe detener el proceso.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: missingCandidate || _claimed ? null : _run,
            child: const Text('Ejecutar una vez'),
          ),
          if (_running) const LinearProgressIndicator(),
          Text('Correctos: ${_counts['passed']} · '
              'Fallidos: ${_counts['failed']} · '
              'Bloqueados: ${_counts['blocked']}'),
          for (final result in _results)
            ListTile(
              title: Text(result.scenarioId),
              subtitle: Text('${result.status.name} · '
                  '${result.elapsedMillis} ms · ${result.category.name}'),
            ),
          if (_artifact != null)
            SelectableText('Informe relativo al soporte privado: $_artifact'),
          if (!_running && _claimed)
            const Text('Los informes anteriores se conservan. Si quedan '
                'fixtures de una interrupción, no borre datos: solicite una '
                'revisión del controlador antes de otra ejecución.'),
          const Text('Esta pantalla no verifica el banner de la aplicación '
              'de producción. No se copia ni se comparte información.'),
        ],
      ),
    );
  }
}
