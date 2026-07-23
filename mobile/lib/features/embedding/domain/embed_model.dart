/// Resolved on-disk paths to the two files that make up the on-device
/// embedding model (roadmap SLICE B1b). flutter_gemma's `installEmbedder()`
/// needs both to activate EmbeddingGemma-300M.
class EmbedModelPaths {
  const EmbedModelPaths({required this.model, required this.tokenizer});

  /// EmbeddingGemma-300M LiteRT weights (`*.tflite`).
  final String model;

  /// Matching SentencePiece tokenizer (`sentencepiece.model`).
  final String tokenizer;
}
