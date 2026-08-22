// El chat que aparecía en blanco.
//
// El usuario lo vivió durante semanas: abría LifeOS, entraba al chat y toda su
// conversación no estaba. Cerrando del todo y volviendo a abrir, aparecía.
//
// La causa NO era la carga —eso ya se reintentaba— sino esto: la conversación
// se busca listando los nodos y, si no aparece, SE CREA UNA NUEVA. Cualquier
// lectura que llegue vacía un instante (la base cifrada abriendo, un fallo
// silenciado) fabrica una segunda conversación con el mismo slug, y todo lo
// dicho se queda colgando de la primera, invisible. El daño es acumulativo:
// cada vez que pasa hay una conversación vacía más.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';

/// Un almacén de mentira que puede fallar la primera lectura, como la de
/// verdad cuando todavía se está abriendo.
class _FlakyStore implements LocalGraphStore {
  _FlakyStore({this.failFirstList = false});

  final bool failFirstList;

  /// La siguiente lectura llega vacía, como cuando la base todavía abre.
  bool emptyOnce = false;
  int listCalls = 0;

  final List<GraphNodeRecord> nodes = [];
  final List<GraphEdgeRecord> edges = [];
  int _seq = 0;

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
      {int? limit, bool includeDeleted = false}) async {
    listCalls++;
    if (listCalls == 1 && failFirstList) {
      throw StateError('la base todavía está abriendo');
    }
    if (emptyOnce) {
      emptyOnce = false;
      return [];
    }
    return nodes.where((n) => n.kind == kind).toList();
  }

  @override
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    String? domain,
    Map<String, Object?> data = const {},
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  }) async {
    final at = DateTime(2026, 8, 22);
    final node = GraphNodeRecord(
      uuid: 'n${_seq++}',
      kind: kind,
      label: label,
      domain: domain,
      data: data,
      localId: _seq,
      createdAt: at,
      updatedAt: at,
    );
    nodes.add(node);
    return node;
  }

  @override
  Future<GraphEdgeRecord> createEdge({
    required String srcUuid,
    required String dstUuid,
    required String relation,
    Map<String, Object?> data = const {},
    String? originNode,
  }) async {
    final at = DateTime(2026, 8, 22);
    final edge = GraphEdgeRecord(
      uuid: 'e${_seq++}',
      srcUuid: srcUuid,
      dstUuid: dstUuid,
      relation: relation,
      data: data,
      createdAt: at,
      updatedAt: at,
    );
    edges.add(edge);
    return edge;
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String nodeUuid,
      {EdgeDirection direction = EdgeDirection.both,
      String? relation,
      bool includeDeleted = false}) async {
    return edges
        .where((e) => e.srcUuid == nodeUuid && e.relation == relation)
        .toList();
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid,
          {bool includeDeleted = false}) async =>
      nodes.where((n) => n.uuid == uuid).firstOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} no hace falta aquí');
}

ChatMessage _msg(String text) => ChatMessage(
      id: text,
      role: ChatRole.user,
      text: text,
      timestamp: DateTime(2026, 8, 22),
    );

void main() {
  group('la conversación no se duplica', () {
    test('si la lectura FALLA, no se crea una conversación nueva', () async {
      // Crear una segunda es lo que hace desaparecer el historial. Fallar
      // ruidosamente permite reintentar; inventar una lo esconde para siempre.
      final store = _FlakyStore(failFirstList: true);
      final repo = ChatHistoryRepository(store);

      await expectLater(repo.loadMessages(), throwsA(isA<Object>()));
      expect(
        store.nodes.where((n) => n.kind == 'conversation'),
        isEmpty,
        reason: 'una lectura fallida no puede fabricar una conversación',
      );
    });

    test('tras el fallo, el siguiente intento encuentra la de siempre',
        () async {
      final store = _FlakyStore();
      final primero = ChatHistoryRepository(store);
      await primero.appendMessage(_msg('hola'));

      // Otro arranque: repositorio nuevo, misma base.
      final segundo = ChatHistoryRepository(store);
      final mensajes = await segundo.loadMessages();

      expect(mensajes.map((m) => m.text), ['hola']);
      expect(
        store.nodes.where((n) => n.kind == 'conversation'),
        hasLength(1),
      );
    });

    test('una lectura VACÍA no fabrica una segunda conversación', () async {
      // El caso real. Ya hay conversación con historial; un arranque la lee
      // vacía por un instante y el código creaba otra — y a partir de ahí el
      // chat abre en blanco.
      final store = _FlakyStore();
      await ChatHistoryRepository(store).appendMessage(_msg('hola'));

      store.emptyOnce = true;
      final tras = ChatHistoryRepository(store);
      await tras.loadMessages().catchError((_) => <ChatMessage>[]);

      expect(
        store.nodes.where((n) => n.kind == 'conversation'),
        hasLength(1),
        reason: 'una lectura vacía no puede fabricar una conversación',
      );
    });

    test('con DOS conversaciones ya duplicadas, se ve todo lo dicho', () async {
      // Los teléfonos que ya sufrieron el fallo llevan la duplicada dentro, y
      // la lista puede devolver primero la vacía. Leer sólo una dejaría media
      // conversación perdida para siempre.
      final store = _FlakyStore();
      final vieja = ChatHistoryRepository(store);
      await vieja.appendMessage(_msg('lo de antes'));

      // La duplicada que dejó el fallo, colocada ANTES en la lista.
      final huerfana = await store.createNode(
        kind: 'conversation',
        label: 'Chat con Axi',
        domain: 'chat',
        data: const {'slug': 'default'},
      );
      store.nodes.removeWhere((n) => n.uuid == huerfana.uuid);
      store.nodes.insert(0, huerfana);

      final leidos = await ChatHistoryRepository(store).loadMessages();

      expect(leidos.map((m) => m.text), contains('lo de antes'));
    });

    test('lo nuevo se escribe SIEMPRE en la misma conversación', () async {
      // Si cada arranque eligiera otra, el historial se repartiría en trozos.
      final store = _FlakyStore();
      await ChatHistoryRepository(store).appendMessage(_msg('uno'));
      await ChatHistoryRepository(store).appendMessage(_msg('dos'));
      await ChatHistoryRepository(store).appendMessage(_msg('tres'));

      expect(store.nodes.where((n) => n.kind == 'conversation'), hasLength(1));
      final leidos = await ChatHistoryRepository(store).loadMessages();
      expect(leidos.map((m) => m.text), ['uno', 'dos', 'tres']);
    });
  });
}
