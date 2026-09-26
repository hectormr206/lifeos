// Every read-aloud attempt, so progress can be HEARD, not just read.
//
// Month one next to month three is the most convincing proof of progress
// there is, and the plan promises it (ODD doc, "visible-results calendar").
// A recording's facts (the sentence, what was understood, the score, when)
// are a graph node of their own kind, encrypted and synced. The audio stays
// sealed on the device that recorded it (the voice-note store encrypts it at
// rest): another device knows the attempt happened and how it scored, and the
// screen says the audio lives elsewhere instead of a button that cannot play.
library;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';

const String kRecordingKind = 'english_recording';
const String _domain = 'learning';
const int _dataVersion = 1;

class Recording {
  const Recording({
    required this.sentence,
    required this.source,
    required this.transcript,
    required this.intelligibility,
    required this.audioPath,
    required this.recordedAt,
  });

  final String sentence;

  /// Where the sentence came from, e.g. `simple.wikipedia.org/Dog`.
  final String source;

  /// What Whisper understood.
  final String transcript;

  /// Share of the sentence's words understood, 0-1.
  final double intelligibility;

  /// The sealed (encrypted) audio on the device that recorded it.
  final String audioPath;
  final DateTime recordedAt;
}

/// What the practice screens need. An interface so they can be tested
/// without the encrypted database.
abstract interface class RecordingArchive {
  Future<void> save(Recording recording);

  /// Newest first.
  Future<List<Recording>> all();
}

class RecordingsRepository implements RecordingArchive {
  RecordingsRepository(this._store);

  final LocalGraphStore _store;

  @override
  Future<void> save(Recording recording) => _store.createNode(
        kind: kRecordingKind,
        label: recording.sentence,
        domain: _domain,
        occurredAt: recording.recordedAt,
        data: {
          // Made by a person practising: any cleanup that reads `source`
          // leaves it alone.
          'source': kRecordingKind,
          'version': _dataVersion,
          'passage': recording.source,
          'transcript': recording.transcript,
          'intelligibility': recording.intelligibility,
          'audioPath': recording.audioPath,
          'recordedAt': recording.recordedAt.toUtc().toIso8601String(),
        },
      );

  @override
  Future<List<Recording>> all() async {
    final recordings = [
      for (final node in await _store.listNodesByKind(kRecordingKind))
        ?_fromNode(node),
    ];
    return recordings..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  }
}

Recording? _fromNode(GraphNodeRecord node) {
  final data = node.data;
  if (data['version'] != _dataVersion) return null;
  final at = DateTime.tryParse('${data['recordedAt']}');
  final score = data['intelligibility'];
  final path = data['audioPath'];
  if (at == null || score is! num || path is! String) return null;
  return Recording(
    sentence: node.label,
    source: '${data['passage'] ?? ''}',
    transcript: '${data['transcript'] ?? ''}',
    intelligibility: score.toDouble(),
    audioPath: path,
    recordedAt: at,
  );
}
