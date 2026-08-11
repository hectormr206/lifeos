import 'dart:typed_data';

import 'llm_request_queue.dart';
import 'local_llm_engine.dart';

/// A [LocalLlmEngine] decorator that funnels every model operation through one
/// [LlmRequestQueue], so the single native session is never asked to do two
/// things at once.
///
/// WHY AT THE ENGINE, NOT AT A CALLER. Chat, the briefing translation, the
/// short-brief writer, the on-demand article summary and the Hacker News
/// comments summary all hold the same [LocalLlmEngine]. A queue added to any
/// one of them leaves the other four racing — and the race the user reported
/// (a running summary cut short by the next tap) crosses those boundaries: a
/// background briefing run generating briefs while the reader taps a summary is
/// the same collision. Wrapping the engine is what makes the guarantee total.
///
/// State-changing operations ([load], [dispose], [installModelFromFile],
/// [deleteModel]) are serialized too: tearing the native handle down underneath
/// a running generation is the most destructive overlap of all.
///
/// [isModelInstalled] and [downloadModel] pass straight through — they touch
/// the filesystem and the downloader, never the inference session, and a
/// multi-minute download must not hold the inference queue.
class SerialLlmEngine implements LocalLlmEngine {
  SerialLlmEngine(this._inner, this._queue);

  final LocalLlmEngine _inner;
  final LlmRequestQueue _queue;

  /// The shared queue, exposed so a caller that wants to show its position can
  /// submit its own composite job (fetch + generate) as ONE slot.
  LlmRequestQueue get queue => _queue;

  @override
  Future<bool> isModelInstalled() => _inner.isModelInstalled();

  @override
  Stream<double> downloadModel() => _inner.downloadModel();

  @override
  Future<void> installModelFromFile(String path) =>
      _queue.add(() => _inner.installModelFromFile(path), label: 'install');

  @override
  Future<void> load({LocalLlmBackend? backend}) =>
      _queue.add(() => _inner.load(backend: backend), label: 'load');

  @override
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  }) =>
      _queue.add(
        () => _inner.generate(prompt, temperature: temperature, topK: topK, topP: topP),
        label: 'generate',
      );

  @override
  Future<GenerationResult> generateWithImages(
    String prompt,
    List<Uint8List> images, {
    double? temperature,
    int? topK,
    double? topP,
  }) =>
      _queue.add(
        () => _inner.generateWithImages(
          prompt,
          images,
          temperature: temperature,
          topK: topK,
          topP: topP,
        ),
        label: 'generate',
      );

  @override
  Future<void> dispose() => _queue.add(_inner.dispose, label: 'dispose');

  @override
  Future<void> deleteModel() => _queue.add(_inner.deleteModel, label: 'delete');
}
