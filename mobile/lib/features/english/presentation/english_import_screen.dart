// "Tu audio o video": the learner's own recordings as reading and listening.
//
// Real people speaking English about things the learner chose: a podcast, a
// talk, a video. The screen says first that the file never leaves the device
// (it is transcribed here) and that up to 20 minutes are used. Then: choose,
// watch the progress, and read the transcript as passages ranked against the
// placement, in the ordinary reader (tap for meaning, save, listen). Every
// failure says what to do next.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../data/audio_importer.dart';
import '../data/wikimedia_reading.dart';
import '../domain/lexical_coverage.dart';
import '../domain/reading_passages.dart';
import 'english_providers.dart';
import 'english_reader_screen.dart';

class EnglishImportScreen extends ConsumerStatefulWidget {
  const EnglishImportScreen({super.key});

  @override
  ConsumerState<EnglishImportScreen> createState() => _EnglishImportScreenState();
}

class _EnglishImportScreenState extends ConsumerState<EnglishImportScreen> {
  bool _working = false;
  ImportProgress? _progress;
  ImportFailure? _failure;
  List<PickedReading> _readings = const [];

  Future<void> _pickAndImport() async {
    final path = await ref.read(audioFilePickerProvider).pick();
    if (path == null || !mounted) return;
    setState(() {
      _working = true;
      _progress = null;
      _failure = null;
      _readings = const [];
    });
    await for (final event in ref.read(audioImporterProvider).importFile(path)) {
      if (!mounted) return;
      switch (event) {
        case ImportProgress():
          setState(() => _progress = event);
        case ImportFailed(:final reason):
          setState(() => _failure = reason);
        case ImportDone(:final title, :final text):
          final readings = await _rank(title, text);
          if (mounted) setState(() => _readings = readings);
      }
    }
    if (mounted) setState(() => _working = false);
  }

  /// The transcript as passages, best fit first. A recording too short for
  /// one full passage is still offered, whole.
  Future<List<PickedReading>> _rank(String title, String text) async {
    final l10n = AppLocalizations.of(context);
    final index = await ref.read(wordIndexProvider.future);
    final placement = await ref.read(latestPlacementProvider.future);
    final known = placement?.result.knownByBand ?? const <double>[];
    final passages = splitPassages(text);
    final ranked = rankPassages(
      passages.isEmpty ? [Passage(text: text, section: '')] : passages,
      index,
      knownByBand: known,
      minWords: 0,
    );
    final article = ReadingArticle(
      site: l10n.englishImportSource,
      title: title,
      license: l10n.englishImportLicense,
    );
    return [for (final r in ranked) PickedReading(article: article, ranked: r)];
  }

  String _failureText(AppLocalizations l10n, ImportFailure failure) =>
      switch (failure) {
        ImportFailure.unsupported => l10n.englishImportUnsupported,
        ImportFailure.cannotDecode => l10n.englishImportCannotDecode,
        ImportFailure.noSpeechModel => l10n.englishImportNoModel,
        ImportFailure.nothingHeard => l10n.englishImportNothingHeard,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final progress = _progress;
    final failure = _failure;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishImportTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.englishImportIntro),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _working ? null : _pickAndImport,
            icon: const Icon(Icons.upload_file),
            label: Text(l10n.englishImportPick),
          ),
          if (_working) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: progress == null ? null : progress.done / progress.total,
            ),
            const SizedBox(height: 8),
            Text(progress == null
                ? l10n.englishImportPreparing
                : l10n.englishImportProgress(progress.done, progress.total)),
          ],
          if (failure != null) ...[
            const SizedBox(height: 16),
            Text(_failureText(l10n, failure),
                style: TextStyle(color: theme.colorScheme.error)),
          ],
          for (final reading in _readings)
            Card(
              child: ListTile(
                title: Text(reading.article.title),
                subtitle: Text(l10n.englishFitLine(
                  switch (reading.ranked.report.fit) {
                    TextFit.easy => l10n.englishFitEasy,
                    TextFit.atLevel => l10n.englishFitAtLevel,
                    TextFit.hard || TextFit.empty => l10n.englishFitHard,
                  },
                  (reading.ranked.report.coverage * 100).round(),
                )),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => EnglishReaderScreen(reading: reading),
                )),
              ),
            ),
        ],
      ),
    );
  }
}
