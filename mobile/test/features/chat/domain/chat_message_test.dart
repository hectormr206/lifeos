// ChatMessage value-equality, status/metrics fields, and copyWith
// (spec mobile-chat + SLICE 1 checkmarks/metrics).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

void main() {
  test('ChatMessage value-equality compares id/role/text/timestamp', () {
    final ts = DateTime.utc(2026, 1, 1);
    final a = ChatMessage(id: '1', role: ChatRole.user, text: 'hola', timestamp: ts);
    final b = ChatMessage(id: '1', role: ChatRole.user, text: 'hola', timestamp: ts);
    final c = ChatMessage(id: '1', role: ChatRole.axi, text: 'hola', timestamp: ts);

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('status and metrics default to null and take part in equality', () {
    final ts = DateTime.utc(2026, 1, 1);
    final plain = ChatMessage(id: '1', role: ChatRole.user, text: 'hola', timestamp: ts);
    expect(plain.status, isNull);
    expect(plain.metrics, isNull);

    final withStatus = ChatMessage(
      id: '1',
      role: ChatRole.user,
      text: 'hola',
      timestamp: ts,
      status: ChatMessageStatus.sent,
    );
    expect(plain, isNot(equals(withStatus)));
  });

  test('copyWith advances status while preserving the other fields', () {
    final ts = DateTime.utc(2026, 1, 1);
    final sending = ChatMessage(
      id: '1',
      role: ChatRole.user,
      text: 'hola',
      timestamp: ts,
      status: ChatMessageStatus.sending,
    );

    final delivered = sending.copyWith(status: ChatMessageStatus.delivered);

    expect(delivered.status, ChatMessageStatus.delivered);
    expect(delivered.id, '1');
    expect(delivered.text, 'hola');
    expect(delivered.timestamp, ts);
  });

  test('copyWith can attach metrics to an axi message', () {
    final ts = DateTime.utc(2026, 1, 1);
    const metrics = GenerationMetrics(
      totalMs: 1000,
      tokensOut: 20,
      backend: LocalLlmBackend.gpu,
      modelId: 'x',
    );
    final axi = ChatMessage(id: 'a', role: ChatRole.axi, text: 'listo', timestamp: ts);

    expect(axi.copyWith(metrics: metrics).metrics, metrics);
  });

  test('transcription defaults to null and takes part in equality', () {
    final ts = DateTime.utc(2026, 1, 1);
    final pending = ChatMessage(
      id: 'v1',
      role: ChatRole.user,
      text: '',
      timestamp: ts,
      kind: ChatMessageKind.voice,
      transcriptionPending: true,
    );
    expect(pending.transcription, isNull);
    expect(pending.hasTranscription, isFalse);

    final transcribed = ChatMessage(
      id: 'v1',
      role: ChatRole.user,
      text: '',
      timestamp: ts,
      kind: ChatMessageKind.voice,
      transcription: 'comprar leche',
    );
    expect(pending, isNot(equals(transcribed)));
    expect(transcribed.hasTranscription, isTrue);
  });

  test('copyWith stores a transcription and clears the pending flag', () {
    final ts = DateTime.utc(2026, 1, 1);
    final pending = ChatMessage(
      id: 'v1',
      role: ChatRole.user,
      text: '',
      timestamp: ts,
      kind: ChatMessageKind.voice,
      audioPath: '/tmp/v.wav',
      transcriptionPending: true,
    );

    final done =
        pending.copyWith(transcription: 'hola mundo', transcriptionPending: false);

    expect(done.transcription, 'hola mundo');
    expect(done.transcriptionPending, isFalse);
    // The bubble label and audio clip are untouched by the transcript store.
    expect(done.text, '');
    expect(done.audioPath, '/tmp/v.wav');
    expect(done.kind, ChatMessageKind.voice);
  });

  test('copyWith(status:) preserves an already-set transcription', () {
    final ts = DateTime.utc(2026, 1, 1);
    final transcribed = ChatMessage(
      id: 'v1',
      role: ChatRole.user,
      text: '',
      timestamp: ts,
      kind: ChatMessageKind.voice,
      transcription: 'algo',
    );

    // Delivery ticks advance on the voice bubble AFTER the transcript is set.
    final delivered = transcribed.copyWith(status: ChatMessageStatus.delivered);
    expect(delivered.transcription, 'algo');
    expect(delivered.status, ChatMessageStatus.delivered);
  });
}
