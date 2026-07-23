// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'LifeOS';

  @override
  String get languageSystem => 'Sistema';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageEnglish => 'English';

  @override
  String get actionClose => 'Cerrar';

  @override
  String get actionRetry => 'Reintentar';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get sectionAppearance => 'Apariencia';

  @override
  String get appearanceLight => 'Claro';

  @override
  String get appearanceDark => 'Oscuro';

  @override
  String get appearanceSystem => 'Sistema';

  @override
  String get sectionRegion => 'Región';

  @override
  String get languageTitle => 'Idioma';

  @override
  String get languageSubtitle => 'Elige el idioma de la app';

  @override
  String get sectionGeneral => 'General';

  @override
  String get localModelTitle => 'Modelo local';

  @override
  String get localModelSubtitle =>
      'Descarga y gestiona el modelo en el dispositivo';

  @override
  String get briefingNavTitle => 'Boletín';

  @override
  String get briefingNavSubtitle =>
      'Genera un boletín matutino en el dispositivo';

  @override
  String get updatesNavTitle => 'Actualizaciones';

  @override
  String get updatesNavSubtitle => 'Buscar e instalar nuevas versiones';

  @override
  String get notificationsNavTitle => 'Notificaciones';

  @override
  String get notificationsNavSubtitle => 'Avisos de nuevas versiones';

  @override
  String get permissionsNavTitle => 'Permisos';

  @override
  String get permissionsNavSubtitle =>
      'Revisa y gestiona los permisos de la app';

  @override
  String get voiceNavTitle => 'Voz';

  @override
  String get voiceNavSubtitle => 'Próximamente';

  @override
  String get sectionAdvanced => 'Avanzado';

  @override
  String get engineConfigTitle => 'Configuración del motor';

  @override
  String get engineConfigSubtitle => 'Parámetros del motor emparejado';

  @override
  String get sectionAbout => 'Acerca de';

  @override
  String appVersionLabel(String name, int build) {
    return 'Versión $name ($build)';
  }

  @override
  String get appVersionLoading => 'Versión…';

  @override
  String get appTagline => 'Axi, siempre contigo ⚡';

  @override
  String get settingsTooltip => 'Ajustes';

  @override
  String get homeNotConnected => 'Aún no está conectado a ningún motor.';

  @override
  String get homeChatOffline => 'Chatear con Axi (sin conexión)';

  @override
  String get homeUseLocalModel => 'Usar modelo local (sin conexión)';

  @override
  String homeConnectedTo(String url) {
    return 'Conectado a $url';
  }

  @override
  String get homeEngineReachable => 'Motor accesible';

  @override
  String get homeEngineUnreachable => 'Motor no accesible';

  @override
  String get homeTalkToAxi => 'Hablar con Axi';

  @override
  String get homeMyData => 'Mis datos';

  @override
  String get homeHowIsAxi => '¿Cómo está Axi?';

  @override
  String get homeReminders => 'Recordatorios';

  @override
  String get homeSummary => 'Resumen';

  @override
  String get homeBulletins => 'Boletines';

  @override
  String get homeTodaySummary => 'Resumen de hoy';

  @override
  String get homeBrain => 'Cerebro';

  @override
  String get homeSettings => 'Ajustes';

  @override
  String get homeLocalModel => 'Modelo local';

  @override
  String get homeMeetings => 'Reuniones';

  @override
  String get homeUpdates => 'Actualizaciones';

  @override
  String get chatTitle => 'Axi';

  @override
  String get chatVoiceReplyTooltip => 'Responder por voz';

  @override
  String get chatVoiceReplyTitle => 'Responder por voz';

  @override
  String get chatVoiceReplySubtitle => 'Próximamente (voz on-device)';

  @override
  String get chatCamera => 'Cámara';

  @override
  String get chatGallery => 'Galería';

  @override
  String chatAttachError(String error) {
    return 'No se pudo adjuntar la imagen: $error';
  }

  @override
  String chatAttachLimit(int count) {
    return 'Puedes adjuntar hasta $count imágenes por mensaje.';
  }

  @override
  String get chatHoldToRecord =>
      'Mantén presionado para grabar una nota de voz';

  @override
  String get chatMicPermissionDenied =>
      'Permiso de micrófono denegado. Actívalo en Ajustes para grabar notas de voz.';

  @override
  String get chatReleaseToCancel => 'Suelta para cancelar';

  @override
  String get chatSlideToCancel => 'Desliza para cancelar';

  @override
  String get chatInputHint => 'Escribe un mensaje…';

  @override
  String get chatAttachTooltip => 'Adjuntar';

  @override
  String get chatSendTooltip => 'Enviar';

  @override
  String get chatWebSearchTooltip => 'Buscar en internet';

  @override
  String get chatModelLoading => 'Cargando el modelo…';

  @override
  String get chatModelLoadError =>
      'No se pudo cargar el modelo. Revísalo e intenta de nuevo.';

  @override
  String get chatTyping => 'Axi está escribiendo…';

  @override
  String get chatStopReading => 'Detener lectura';

  @override
  String get chatListenReply => 'Escuchar respuesta';

  @override
  String get chatMetricsTitle => 'Métricas de la respuesta';

  @override
  String get metricSpeed => 'Velocidad';

  @override
  String get metricTokens => 'Tokens generados';

  @override
  String get metricTokensApprox => ' (aprox.)';

  @override
  String get metricTotalTime => 'Tiempo total';

  @override
  String get metricTtft => 'Primer token (TTFT)';

  @override
  String get metricUnavailable => 'No disponible';

  @override
  String get metricBackend => 'Backend';

  @override
  String get metricModel => 'Modelo';

  @override
  String get chatTranscriptionPending => 'Transcripción pendiente (STT)';

  @override
  String get sttTranscribing => 'Transcribiendo…';

  @override
  String get sttDownloadVoiceModel => 'Descargar modelo de voz';

  @override
  String sttDownloadingVoiceModel(Object percent) {
    return 'Descargando modelo de voz… $percent%';
  }

  @override
  String get sttVoiceModelReady => 'Modelo de voz listo';

  @override
  String get sttVoiceModelFailed =>
      'No se pudo descargar el modelo de voz. Toca para reintentar.';

  @override
  String get ttsDownloadVoice => 'Descargar voz neuronal';

  @override
  String ttsDownloadingVoice(Object percent) {
    return 'Descargando voz neuronal… $percent%';
  }

  @override
  String get ttsVoiceReady => 'Voz neuronal lista';

  @override
  String get ttsVoiceFailed =>
      'No se pudo descargar la voz neuronal. Mientras tanto se usará la voz del sistema.';

  @override
  String get briefingTitle => 'Boletín';

  @override
  String get briefingSourcesTooltip => 'Fuentes';

  @override
  String get briefingGenerating => 'Generando…';

  @override
  String get briefingGenerateNow => 'Generar boletín ahora';

  @override
  String get briefingEmptyTitle => 'Aún no hay boletín';

  @override
  String get briefingEmptyBody =>
      'Toca \"Generar boletín ahora\" y Axi leerá tus fuentes y las resumirá en el dispositivo.';

  @override
  String get briefingHeaderTitle => 'Boletín matutino';

  @override
  String briefingGeneratedAt(String datetime) {
    return 'Generado el $datetime';
  }

  @override
  String get briefingLinkCopied => 'Enlace copiado al portapapeles';
}
