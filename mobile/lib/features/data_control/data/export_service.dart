// Writing the export to a file and handing it to the user.
//
// The FORMAT lives in domain/export.dart with its own tests; this is the thin
// part that touches the disk and the platform. Kept apart on purpose: what
// goes into the file is the thing that must be right, and it should be
// testable without a device.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/export.dart';

/// What the user asked for.
enum ExportFormat { json, csv }

class ExportService {
  ExportService(
    this._store, {
    DateTime Function()? now,
    Future<Directory> Function()? directory,
  })  : _now = now ?? DateTime.now,
        // Injected so a test can write to a real temp dir without a platform
        // channel — and so the one thing that must be right (what goes in the
        // file) is testable without a device.
        _directory = directory ?? getTemporaryDirectory;

  final LocalGraphStore _store;
  final DateTime Function() _now;
  final Future<Directory> Function() _directory;

  /// Build the file and return it. Does NOT share it — the caller decides,
  /// so a test can check the contents without a share sheet appearing.
  Future<File> writeExport(ExportFormat format) async {
    // Deleted rows included: a tombstone is part of the truth about the graph,
    // and leaving them out would make the file disagree with what syncs
    // between the user's own devices.
    final nodes = <GraphNodeRecord>[];
    for (final kind in const ['fact', 'person', 'conversation', 'reminder']) {
      nodes.addAll(await _store.listNodesByKind(kind, includeDeleted: true));
    }

    final at = _now();
    final stamp = '${at.year}${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}';

    final String contents;
    final String name;
    if (format == ExportFormat.csv) {
      contents = exportGraphAsCsv(nodes: nodes);
      name = 'lifeos-$stamp.csv';
    } else {
      final edges = <GraphEdgeRecord>[];
      for (final node in nodes) {
        for (final edge
            in await _store.edgesForNode(node.uuid, includeDeleted: true)) {
          if (!edges.any((e) => e.uuid == edge.uuid)) edges.add(edge);
        }
      }
      contents = exportGraphAsJson(
        nodes: nodes,
        edges: edges,
        generatedAt: at,
      );
      name = 'lifeos-$stamp.json';
    }

    // The app's own temp directory: the file is handed straight to the share
    // sheet, so it never needs storage permissions and never lands somewhere
    // another app could read on its own.
    final dir = await _directory();
    final file = File('${dir.path}/$name');
    await file.writeAsString(contents, flush: true);
    return file;
  }

  /// Write it and offer it to the system: save to Files, send by mail, put it
  /// on a USB stick. LifeOS does not decide where someone's own data goes.
  Future<void> shareExport(ExportFormat format) async {
    final file = await writeExport(format);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'LifeOS — mis datos',
      ),
    );
  }
}
