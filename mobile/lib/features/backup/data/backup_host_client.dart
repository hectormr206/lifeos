import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../domain/backup_host_config.dart';
import '../domain/backup_host_diagnosis.dart';

/// Talks to the user's own backup host over their private network.
///
/// A FRESH `dio`, not the paired-engine client: this host is the user's own
/// server on a VPN address, so it must not inherit the engine base URL, its
/// auth headers, or its TLS pinning.
///
/// What it uploads is already sealed with the user's passphrase, so this class
/// never sees plaintext and the transport is not what protects the data. The
/// VPN is defence in depth: personal data should not be *reachable* on the
/// public internet, not merely unreadable there.
class BackupHostClient {
  BackupHostClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              // Generous: an archive is large and a phone's uplink is not.
              sendTimeout: const Duration(minutes: 5),
              receiveTimeout: const Duration(minutes: 5),
              // Read the body ourselves rather than letting dio throw deep;
              // the status IS the diagnosis here.
              validateStatus: (status) => status != null && status < 600,
            ));

  final Dio _dio;
  static const String _keyHeader = 'X-LifeOS-Backup-Key';

  /// The status IS the diagnosis here — 401 means "wrong key", 507 means "no
  /// room" — so every request opts out of dio's throw-on-non-2xx. Set per
  /// request rather than only in the default BaseOptions: otherwise the
  /// client's behaviour would silently depend on how an injected Dio happens
  /// to be configured, and a wrong key would surface as a network error.
  static Options _readable([Map<String, dynamic>? headers]) => Options(
        headers: headers,
        validateStatus: (status) => status != null && status < 600,
      );

  /// Walks the three rungs — reachable, authorised, usable — and stops at the
  /// first that fails, so the user is told the ONE thing to fix.
  Future<BackupHostDiagnosis> diagnose(BackupHostConfig config) async {
    if (!config.isComplete) {
      return const BackupHostDiagnosis(
        state: BackupHostState.notConfigured,
        message: 'Todavía no configuraste un servidor de respaldo.',
      );
    }

    // Rung 1 — is anything there? Unauthenticated on purpose, so a wrong
    // address is distinguishable from a wrong key.
    final Response<dynamic> health;
    try {
      health = await _dio.getUri(
        Uri.parse(config.endpoint('/v1/health')),
        options: _readable(),
      );
    } on DioException {
      return const BackupHostDiagnosis(
        state: BackupHostState.unreachable,
        message: 'No se pudo contactar el servidor. Revisa que este dispositivo '
            'esté conectado a la VPN y que la dirección sea correcta.',
      );
    }

    if (!_looksLikeBackupHost(health)) {
      return const BackupHostDiagnosis(
        state: BackupHostState.notABackupHost,
        message: 'Algo respondió en esa dirección, pero no es un servidor de '
            'respaldo de LifeOS. Revisa la dirección y el puerto.',
      );
    }

    // Rung 2 and 3 — the key, then whether the store can actually hold data.
    final Response<dynamic> status;
    try {
      status = await _dio.getUri(
        Uri.parse(config.endpoint('/v1/status')),
        options: _readable({_keyHeader: config.accessKey}),
      );
    } on DioException {
      return const BackupHostDiagnosis(
        state: BackupHostState.unreachable,
        message: 'El servidor dejó de responder a mitad de la comprobación.',
      );
    }

    if (status.statusCode == 401 || status.statusCode == 403) {
      return const BackupHostDiagnosis(
        state: BackupHostState.keyRejected,
        message: 'El servidor está, pero rechazó la clave de acceso. '
            'Copiala de nuevo, sin espacios ni saltos de línea.',
      );
    }

    final body = _asMap(status.data);
    if (body['writable'] != true) {
      return const BackupHostDiagnosis(
        state: BackupHostState.storeNotWritable,
        message: 'El servidor responde pero no puede guardar nada: el disco '
            'está lleno o el volumen es de solo lectura.',
      );
    }

    return BackupHostDiagnosis(
      state: BackupHostState.ready,
      message: 'Listo para respaldar.',
      freeBytes: _asInt(body['freeBytes']),
      backupCount: _asInt(body['backups']),
    );
  }

  /// Stores an already-sealed archive under [name]. Throws rather than
  /// returning a result: a backup that did not land must never be mistaken
  /// for one that did.
  Future<void> upload(
    BackupHostConfig config, {
    required String name,
    required Uint8List sealed,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.putUri(
        Uri.parse(config.endpoint('/v1/backups/$name')),
        data: Stream.value(sealed),
        options: _readable({
          _keyHeader: config.accessKey,
          Headers.contentLengthHeader: sealed.length,
          Headers.contentTypeHeader: 'application/octet-stream',
        }),
      );
    } on DioException {
      throw const BackupHostException(
        BackupHostState.unreachable,
        'Se cortó la conexión con el servidor. El respaldo NO se guardó.',
      );
    }

    final status = response.statusCode ?? 0;
    if (status == 201 || status == 200) return;
    if (status == 401 || status == 403) {
      throw const BackupHostException(
        BackupHostState.keyRejected,
        'El servidor rechazó la clave de acceso.',
      );
    }
    if (status == 507 || status == 413) {
      throw const BackupHostException(
        BackupHostState.storeNotWritable,
        'El servidor no pudo guardar el archivo: sin espacio o de solo lectura.',
      );
    }
    throw BackupHostException(
      BackupHostState.notABackupHost,
      'Respuesta inesperada del servidor (HTTP $status).',
    );
  }

  /// What the server currently holds, newest first — restoring almost always
  /// means "the last one", so that is what should be at the top.
  Future<List<RemoteBackup>> list(BackupHostConfig config) async {
    final Response<dynamic> response;
    try {
      response = await _dio.getUri(
        Uri.parse(config.endpoint('/v1/backups')),
        options: _readable({_keyHeader: config.accessKey}),
      );
    } on DioException {
      throw const BackupHostException(
        BackupHostState.unreachable,
        'No se pudo contactar el servidor. ¿Estás en la VPN?',
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const BackupHostException(
        BackupHostState.keyRejected,
        'El servidor rechazó la clave de acceso.',
      );
    }

    final raw = _asMap(response.data)['backups'];
    final entries = <RemoteBackup>[
      if (raw is List)
        for (final item in raw)
          if (item is Map)
            RemoteBackup(
              name: '${item['name']}',
              sizeBytes: _asInt(item['sizeBytes']) ?? 0,
              modifiedAt:
                  DateTime.tryParse('${item['modifiedAt']}')?.toLocal() ??
                      DateTime.fromMillisecondsSinceEpoch(0),
            ),
    ]..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return entries;
  }

  /// The sealed bytes, exactly as stored. Throws rather than returning empty
  /// on a miss: empty bytes would sail into the unsealer and surface as
  /// "wrong passphrase", sending the user to debug the one thing that was fine.
  Future<Uint8List> download(
    BackupHostConfig config, {
    required String name,
  }) async {
    final Response<List<int>> response;
    try {
      response = await _dio.getUri<List<int>>(
        Uri.parse(config.endpoint('/v1/backups/$name')),
        options: Options(
          headers: {_keyHeader: config.accessKey},
          responseType: ResponseType.bytes,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
    } on DioException {
      throw const BackupHostException(
        BackupHostState.unreachable,
        'Se cortó la descarga. El archivo NO se recuperó completo.',
      );
    }

    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw const BackupHostException(
        BackupHostState.keyRejected,
        'El servidor rechazó la clave de acceso.',
      );
    }
    final bytes = response.data;
    if (status != 200 || bytes == null || bytes.isEmpty) {
      throw BackupHostException(
        BackupHostState.notABackupHost,
        'El servidor no devolvió el archivo «$name» (HTTP $status).',
      );
    }
    return Uint8List.fromList(bytes);
  }

  /// Only a host that identifies itself counts. Anything else answering the
  /// port — a router page, a proxy, a captive portal — is not a backup host,
  /// and saying "connected" about it would mislead the user into trusting it.
  bool _looksLikeBackupHost(Response<dynamic> response) {
    if (response.statusCode != 200) return false;
    return _asMap(response.data)['service'] == 'lifeos-backup-host';
  }

  Map<String, dynamic> _asMap(dynamic data) =>
      data is Map ? data.cast<String, dynamic>() : const {};

  int? _asInt(dynamic value) => value is int
      ? value
      : (value is num ? value.toInt() : int.tryParse('$value'));
}
