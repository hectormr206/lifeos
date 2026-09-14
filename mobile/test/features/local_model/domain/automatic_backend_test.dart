import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

void main() {
  group('automaticBackendFor', () {
    test('en el móvil pide GPU: el prefill ahí sí gana', () {
      expect(automaticBackendFor(TargetPlatform.android), LocalLlmBackend.gpu);
      expect(automaticBackendFor(TargetPlatform.iOS), LocalLlmBackend.gpu);
    });

    test('en escritorio pide CPU y no toca la VRAM', () {
      expect(automaticBackendFor(TargetPlatform.linux), LocalLlmBackend.cpu);
      expect(automaticBackendFor(TargetPlatform.windows), LocalLlmBackend.cpu);
      expect(automaticBackendFor(TargetPlatform.macOS), LocalLlmBackend.cpu);
      expect(automaticBackendFor(TargetPlatform.fuchsia), LocalLlmBackend.cpu);
    });
  });

  group('LocalModelConfig.backend', () {
    test('sin elección, es el automático de esta plataforma', () {
      expect(
        const LocalModelConfig().backend,
        automaticBackendFor(defaultTargetPlatform),
      );
    });

    test('una elección explícita del usuario manda siempre', () {
      expect(const LocalModelConfig(backend: LocalLlmBackend.gpu).backend, LocalLlmBackend.gpu);
      expect(const LocalModelConfig(backend: LocalLlmBackend.cpu).backend, LocalLlmBackend.cpu);
      expect(const LocalModelConfig(backend: LocalLlmBackend.npu).backend, LocalLlmBackend.npu);
    });
  });
}
