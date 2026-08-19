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
  String get homeDictate => 'Dictar';

  @override
  String get dictateTitle => 'Dictar';

  @override
  String get dictateTagline => 'Habla y Axi te escucha';

  @override
  String get dictateIdleHint => 'Toca el micrófono y habla';

  @override
  String get dictateRecordingHint => 'Te escucho… toca para terminar';

  @override
  String get dictateTranscribingHint => 'Transcribiendo en este dispositivo…';

  @override
  String get dictateReviewHint => 'Revisa el texto antes de enviarlo';

  @override
  String get dictateSend => 'Enviar a Axi';

  @override
  String get dictateCopy => 'Copiar';

  @override
  String get dictateCopied => 'Texto copiado';

  @override
  String get dictateDiscard => 'Descartar';

  @override
  String get dictateRetry => 'Probar de nuevo';

  @override
  String get dictateModelMissing =>
      'El modelo de voz no está descargado en este dispositivo.';

  @override
  String get dictateDownloadModel => 'Descargar modelo de voz';

  @override
  String get dictateMicDenied =>
      'Sin permiso de micrófono, no puedo escucharte.';

  @override
  String get dictateRecorderUnavailable => 'No se pudo abrir el micrófono.';

  @override
  String get dictateRecorderDesktopHint =>
      'En Linux la grabación usa «parecord» y «ffmpeg». Instalalos con tu gestor de paquetes (en Arch: sudo pacman -S --needed libpulse ffmpeg).';

  @override
  String get domainTabLocal => 'En este dispositivo';

  @override
  String get domainTabEngine => 'Desde el motor Axi';

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
  String get actionCancel => 'Cancelar';

  @override
  String get actionDelete => 'Eliminar';

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
  String get sectionRegion => 'Idioma';

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
  String get webSearchNavTitle => 'Búsqueda web';

  @override
  String get webSearchNavSubtitle => 'Elige tu proveedor de búsqueda';

  @override
  String get webSearchSettingsTitle => 'Búsqueda web';

  @override
  String get webSearchSettingsIntro =>
      'Elige cómo el chat busca en internet cuando el globo está activo.';

  @override
  String get webSearchProviderDuckduckgo => 'DuckDuckGo';

  @override
  String get webSearchProviderDuckduckgoDesc =>
      'Público, sin configurar, best-effort. Solo tu consulta sale del dispositivo.';

  @override
  String get webSearchProviderSearxng => 'Tu propio SearXNG';

  @override
  String get webSearchProviderSearxngDesc =>
      'Una instancia de SearXNG que tú alojas. Privado: la consulta va a un servidor que controlas.';

  @override
  String get webSearchProviderNone => 'Ninguna';

  @override
  String get webSearchProviderNoneDesc =>
      'Búsqueda web desactivada. Nunca se hace ninguna solicitud de búsqueda.';

  @override
  String get webSearchSearxngUrlLabel => 'URL de tu instancia SearXNG';

  @override
  String get webSearchTestConnection => 'Probar conexión';

  @override
  String get webSearchTesting => 'Probando…';

  @override
  String get webSearchTestSuccess => 'Conexión exitosa';

  @override
  String get webSearchTestFailure => 'No se pudo conectar';

  @override
  String get updatesNavTitle => 'Actualizaciones';

  @override
  String get updatesNavSubtitle =>
      'Buscar, instalar y avisar de nuevas versiones';

  @override
  String get updateBannerDismissTooltip => 'Recordármelo mañana';

  @override
  String get desktopUpdateWaiting =>
      'Instalando la actualización… puede tardar unos minutos.';

  @override
  String desktopUpdateApplied(String version) {
    return 'LifeOS $version se instaló correctamente.';
  }

  @override
  String get desktopUpdateAppliedUnnamed =>
      'La actualización se instaló correctamente.';

  @override
  String get desktopUpdateRestarting =>
      'Reiniciando LifeOS con la nueva versión…';

  @override
  String get desktopUpdateNotWatched =>
      'El actualizador del sistema no respondió: la solicitud sigue pendiente y nadie la recogió. Reinstala con install-linux.sh para habilitar las actualizaciones automáticas.';

  @override
  String desktopUpdateNotConfirmed(String version) {
    return 'No pude confirmar que la actualización se aplicara. Sigues en la versión $version. Vuelve a intentarlo, o ejecuta install-linux.sh desde una terminal para ver por qué falló.';
  }

  @override
  String get desktopUpdateNotConfirmedUnnamed =>
      'No pude confirmar que la actualización se aplicara. Vuelve a intentarlo, o ejecuta install-linux.sh desde una terminal para ver por qué falló.';

  @override
  String get permissionsNavTitle => 'Permisos';

  @override
  String get permissionsNavSubtitle =>
      'Revisa y gestiona los permisos de la app';

  @override
  String get timezoneNavTitle => 'Zona horaria';

  @override
  String get timezoneNavSubtitle => 'Automática o elige una zona manualmente';

  @override
  String get timezoneTitle => 'Zona horaria';

  @override
  String get timezoneAutomaticLabel => 'Automática (usar la del dispositivo)';

  @override
  String get timezoneAutomaticSubtitle =>
      'Detecta la zona de tu dispositivo, con horario de verano.';

  @override
  String timezoneDetectedLabel(String zone) {
    return 'Detectada: $zone';
  }

  @override
  String get timezoneSearchHint => 'Buscar zona…';

  @override
  String get timezoneNoResults => 'Sin resultados';

  @override
  String get voiceNavTitle => 'Voz';

  @override
  String get voiceNavSubtitle =>
      'Cómo habla Axi: voz natural y lectura automática';

  @override
  String get voiceScreenTitle => 'Voz';

  @override
  String get voiceAutoSpeakTitle => 'Responder por voz';

  @override
  String get voiceAutoSpeakSubtitle => 'Axi lee cada respuesta en voz alta';

  @override
  String get voiceStatusReady => 'Voz natural activa';

  @override
  String get voiceStatusReadyDetail =>
      'Axi habla con la voz neuronal en tu dispositivo.';

  @override
  String voiceStatusDownloading(int percent) {
    return 'Descargando la voz natural… $percent%';
  }

  @override
  String get voiceStatusAbsent => 'Usando la voz del sistema';

  @override
  String get voiceStatusAbsentDetail =>
      'Descarga la voz natural para que Axi suene más humano.';

  @override
  String get voiceStatusFailed => 'No se pudo descargar la voz natural';

  @override
  String get voiceDownloadButton => 'Descargar voz natural';

  @override
  String get voiceRetryButton => 'Reintentar';

  @override
  String get voiceRateLabel => 'Velocidad';

  @override
  String get voiceRateSlow => 'Lenta';

  @override
  String get voiceRateFast => 'Rápida';

  @override
  String get voiceTestButton => 'Probar voz';

  @override
  String get voiceSampleText =>
      'Hola, soy Axi. Así sonará mi voz cuando te lea tus respuestas.';

  @override
  String get voiceTestSpokeNeural =>
      'Listo. Reproduje la muestra con la voz natural.';

  @override
  String get voiceTestSpokeSystemVoiceMissing =>
      'Sonó la voz del dispositivo: la voz natural aún no está descargada.';

  @override
  String get voiceTestSpokeSystem =>
      'Sonó la voz del dispositivo: la voz natural no pudo reproducirse esta vez.';

  @override
  String get voiceTestFailedVoiceMissing =>
      'La voz natural no está descargada en este dispositivo.';

  @override
  String get voiceTestFailedVoiceIncompatible =>
      'Esta voz no funciona en este dispositivo. Elige otra.';

  @override
  String get voiceTestFailedSynthesis =>
      'La voz natural falló al generar el audio.';

  @override
  String get voiceTestFailedEmpty => 'La voz se ejecutó, pero no generó audio.';

  @override
  String get voiceTestFailedPlayback =>
      'El audio se generó, pero este dispositivo no pudo reproducirlo.';

  @override
  String get voiceTestFailedNoEngine =>
      'Ninguna voz respondió: ni la natural ni la del dispositivo.';

  @override
  String get voiceTestFailedUnknown =>
      'La prueba falló y no pude identificar la causa.';

  @override
  String get voiceLanguageNote =>
      'La voz sigue el idioma de la app (Región / Idioma).';

  @override
  String get voiceCatalogNavTitle => 'Elegir voz';

  @override
  String get voiceCatalogNavSubtitle =>
      'Explora, preescucha y descarga más voces';

  @override
  String get voiceCatalogTitle => 'Elegir voz';

  @override
  String get voiceCatalogGroupSpanish => 'Español';

  @override
  String get voiceCatalogGroupEnglish => 'Inglés';

  @override
  String get voiceCatalogPreviewButton => 'Preescuchar';

  @override
  String get voiceCatalogUseButton => 'Usar esta voz';

  @override
  String get voiceCatalogSelectedBadge => 'Seleccionada';

  @override
  String get voiceCatalogDownloadButton => 'Descargar';

  @override
  String get voiceCatalogStatusInstalled => 'Descargada';

  @override
  String get voiceCatalogStatusAbsent => 'Sin descargar';

  @override
  String voiceCatalogStatusDownloading(int percent) {
    return 'Descargando… $percent%';
  }

  @override
  String get voiceCatalogStatusFailed => 'Error al descargar';

  @override
  String get voiceCatalogSampleEs => 'Hola, soy Axi, tu asistente personal.';

  @override
  String get voiceCatalogSampleEn => 'Hi, I\'m Axi, your personal assistant.';

  @override
  String get voiceIncompatibleMessage =>
      'Esta voz no es compatible en este dispositivo.';

  @override
  String get voiceCatalogRegionMexico => 'México';

  @override
  String get voiceCatalogRegionSpain => 'España';

  @override
  String get voiceCatalogRegionArgentina => 'Argentina';

  @override
  String get voiceCatalogRegionUnitedStates => 'Estados Unidos';

  @override
  String get voiceCatalogRegionUnitedKingdom => 'Reino Unido';

  @override
  String get voiceCatalogDeleteButton => 'Eliminar';

  @override
  String get voiceCatalogDeleteTitle => '¿Eliminar esta voz?';

  @override
  String voiceCatalogDeleteMessage(String voice) {
    return 'Se borrarán los archivos de $voice de este dispositivo. Podrás volver a descargarla cuando quieras.';
  }

  @override
  String voiceCatalogDeleteSelectedMessage(String voice) {
    return '$voice es tu voz activa. Se borrará de este dispositivo y la app usará otra voz descargada, o la voz del dispositivo si no queda ninguna.';
  }

  @override
  String get voiceCatalogDeleteConfirm => 'Eliminar';

  @override
  String get voiceCatalogDeleteCancel => 'Cancelar';

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
  String get appVersionUnknown => 'Versión desconocida';

  @override
  String get installedVersionUnknown =>
      'No se pudo determinar la versión instalada.';

  @override
  String installedVersionBuildOnly(int build) {
    return 'Compilación $build';
  }

  @override
  String get appTagline => 'Axi, siempre contigo ⚡';

  @override
  String get aboutSlogan => 'Tu vida, tu máquina, no su nube.';

  @override
  String get aboutAuthor => 'Creado por Héctor Martínez';

  @override
  String get aboutLandingLink => 'lifeos.hectormr.com';

  @override
  String get requiredModelsSectionTitle => 'Modelos necesarios';

  @override
  String get requiredModelsSectionSubtitle =>
      'LifeOS funciona por completo sin conexión cuando estos cuatro modelos están instalados.';

  @override
  String get requiredModelsDownloadAll => 'Descargar todo';

  @override
  String get requiredModelsContinue => 'Continuar descarga';

  @override
  String get requiredModelsWifiNote =>
      'Te recomendamos conectarte a Wi-Fi para la descarga inicial (~2.9 GB).';

  @override
  String requiredModelsOverall(int ready, int total, int percent) {
    return 'Preparando LifeOS — $ready de $total · $percent%';
  }

  @override
  String get requiredModelStatusInstalled => 'Instalado';

  @override
  String requiredModelStatusDownloading(int percent) {
    return 'Descargando $percent%';
  }

  @override
  String get requiredModelStatusAvailable => 'Disponible para descargar';

  @override
  String get requiredModelStatusError => 'Error en la descarga';

  @override
  String get modelNameBrain => 'Cerebro';

  @override
  String get modelNameStt => 'Oído (voz a texto)';

  @override
  String get modelNameTts => 'Voz (Piper)';

  @override
  String get modelNameEmbed => 'Memoria (embeddings)';

  @override
  String get chatPreparingTitle => 'Preparando LifeOS';

  @override
  String get chatPreparingBody =>
      'Descarga los modelos necesarios para chatear sin conexión.';

  @override
  String get settingsTooltip => 'Ajustes';

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
  String get homeMyData => 'Registrar por categoría';

  @override
  String get homeMyDataSubtitle => 'Salud, finanzas, ejercicio, relaciones…';

  @override
  String get homeMyLife => 'Mi vida';

  @override
  String get homeMyLifeSubtitle => 'Todo lo que registras, por persona';

  @override
  String get homeSectionRecords => 'Tus registros';

  @override
  String get homeSectionAxi => 'Axi';

  @override
  String get homeSectionNotices => 'Avisos y resúmenes';

  @override
  String get homeSectionSystem => 'Ajustes y sistema';

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
  String get homeBrainEngine => 'Cerebro del motor';

  @override
  String get homeSettings => 'Ajustes';

  @override
  String get homeLocalModel => 'Modelo local';

  @override
  String get homeMeetings => 'Reuniones';

  @override
  String get homeUpdates => 'Actualizaciones';

  @override
  String get axiAvatarLabel =>
      'Axi — agente vivo. Toca un órgano para explorarlo.';

  @override
  String get axiOrganComingSoon => 'Próximamente en este dispositivo';

  @override
  String get brain3dTitle => 'Cerebro 3D';

  @override
  String get brain3dEmpty =>
      'Aún no hay recuerdos en el grafo local. Conversa con Axi y su cerebro crecerá.';

  @override
  String brain3dSparse(int nodes) {
    return 'Por ahora Axi recuerda $nodes cosa(s). Un cerebro necesita al menos tres para dibujar relaciones — contale un par más y esta pantalla cobra vida.';
  }

  @override
  String brain3dSummary(int nodes, int edges) {
    return '$nodes nodos · $edges enlaces en el grafo local';
  }

  @override
  String get chatTitle => 'Axi';

  @override
  String get chatVoiceReplyTooltip => 'Responder por voz';

  @override
  String get chatVoiceReplyTitle => 'Responder por voz';

  @override
  String get chatVoiceReplySubtitle =>
      'Axi lee cada nueva respuesta en voz alta.';

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
  String get chatOnboardingGreeting =>
      'Hola, soy Axi 🐾 — tu asistente, y todo lo que me cuentes vive solo en este dispositivo. Para empezar: ¿cómo te gusta que te llame?';

  @override
  String chatOnboardingNameConfirm(String name) {
    return '¡Mucho gusto, $name! ¿En qué te ayudo?';
  }

  @override
  String chatCaptureAck(String domain, String detail) {
    return 'Anotado en $domain: $detail.';
  }

  @override
  String chatCaptureAckSubject(String domain, String subject, String detail) {
    return 'Anotado en $domain ($subject): $detail.';
  }

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
  String get chatShowTranscription => 'Ver transcripción';

  @override
  String get chatHideTranscription => 'Ocultar transcripción';

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

  @override
  String get briefingOpenFailed => 'No se pudo abrir la noticia.';

  @override
  String get briefingCopyLinkAction => 'Copiar enlace';

  @override
  String get briefingCopyFailed => 'No se pudo copiar el enlace.';

  @override
  String get briefingScheduleTitle => 'Boletín automático';

  @override
  String get briefingScheduleSubtitle =>
      'Genera el boletín cada día a la hora elegida, incluso con LifeOS cerrada. Si el sistema pospone la tarea, recibirás un aviso para generarlo con un toque.';

  @override
  String get briefingScheduleTimeLabel => 'Hora del boletín';

  @override
  String get briefingOpenArticle => 'Ver noticia completa →';

  @override
  String get briefingFullSummary => 'Ver resumen completo';

  @override
  String get briefingHideFullSummary => 'Ocultar resumen completo';

  @override
  String get briefingCommentsSummary => 'Ver resumen de comentarios';

  @override
  String get briefingHideCommentsSummary => 'Ocultar resumen de comentarios';

  @override
  String get briefingSummarizing => 'Resumiendo…';

  @override
  String get briefingSummarizingComments => 'Resumiendo comentarios…';

  @override
  String get briefingSummaryQueued => 'En cola…';

  @override
  String get briefingSummaryQueuedHint =>
      'Empezará en cuanto termine el resumen en curso.';

  @override
  String get briefingSummaryErrorNoModel =>
      'El resumen se escribe en este dispositivo y no hay ningún modelo instalado.';

  @override
  String get briefingSummaryInstallModelAction => 'Descargar un modelo';

  @override
  String get briefingSummaryErrorModelLoad =>
      'Hay un modelo instalado, pero no se pudo usar para escribir este resumen.';

  @override
  String get briefingSummaryErrorFetch =>
      'No se pudo descargar la página del artículo. Puede ser la conexión, o el sitio rechazándola.';

  @override
  String get briefingSummaryErrorUnreadable =>
      'La página se descargó, pero no tiene texto legible (puede estar tras un muro de pago o construida con JavaScript).';

  @override
  String get briefingCommentsErrorFetch =>
      'No se pudo descargar el hilo de comentarios. Puede ser la conexión, o Hacker News rechazándolo.';

  @override
  String get briefingCommentsErrorNone =>
      'Este hilo no tiene comentarios que resumir.';

  @override
  String get briefingSummaryErrorEmpty =>
      'El modelo terminó sin escribir nada.';

  @override
  String get briefingSummaryErrorUnknown =>
      'El resumen falló y no se pudo identificar el motivo.';

  @override
  String get engineErrorDetailsShow => 'Ver detalles técnicos';

  @override
  String get engineErrorDetailsHide => 'Ocultar detalles técnicos';

  @override
  String get engineErrorDetailsCopy => 'Copiar detalles';

  @override
  String get engineErrorDetailsCopied => 'Detalles técnicos copiados.';

  @override
  String get engineErrorDetailsFailed => 'No se pudieron copiar los detalles.';

  @override
  String get briefingTranslationFailed =>
      'Algunos elementos se muestran en su idioma original: el modelo no pudo traducirlos.';

  @override
  String get briefingModelSlowBackend =>
      'El modelo se está ejecutando sin aceleración por hardware, así que tardará bastante más de lo normal.';

  @override
  String get briefingSummaryRetryAction => 'Reintentar';

  @override
  String briefingSummaryRetryFailedAgain(int attempt) {
    return 'Volvió a fallar (intento $attempt).';
  }

  @override
  String get briefingSummaryNotRetryable =>
      'Reintentar no cambiaría el resultado.';

  @override
  String get briefingTranslating => 'Traduciendo…';

  @override
  String get briefingNoSummaryHint =>
      'Sin resumen: la fuente no lo trae y no se pudo leer la página.';

  @override
  String briefingSkippedSources(String sources) {
    return 'Sin novedades hoy: $sources';
  }

  @override
  String get chatDeleteMessage => 'Eliminar mensaje';

  @override
  String get chatDeleteMessagePairNote =>
      'Se eliminará tu mensaje y la respuesta de Axi.';

  @override
  String get chatDeleteConversation => 'Eliminar conversación';

  @override
  String get chatDeleteConversationTitle => '¿Eliminar la conversación?';

  @override
  String get chatDeleteConversationBody =>
      'Se eliminarán los mensajes, los recuerdos que Axi derivó de esta conversación y sus notas de voz en este dispositivo.';

  @override
  String get backupsNavTitle => 'Copias de seguridad';

  @override
  String get backupsNavSubtitle => 'Crea y restaura copias de tus datos';

  @override
  String get backupsTitle => 'Copias de seguridad';

  @override
  String get backupsCreateNow => 'Crear copia ahora';

  @override
  String get backupsAutoSection => 'Automáticas';

  @override
  String get backupsManualSection => 'Manuales';

  @override
  String get backupsEmpty =>
      'Aún no hay copias. LifeOS crea una automáticamente cada día al abrir la app.';

  @override
  String get backupsCreated => 'Copia creada';

  @override
  String get backupsDeleted => 'Copia eliminada';

  @override
  String get backupsDeleteTooltip => 'Eliminar copia';

  @override
  String get backupsPreRestoreLabel =>
      'Copia pre-restauración (tus datos anteriores)';

  @override
  String get backupsRestoreTitle => '¿Restaurar esta copia?';

  @override
  String get backupsRestoreBody =>
      'Primero se guardan tus datos actuales como copia \"pre-restauración\", así siempre puedes regresar a ellos desde esta lista.';

  @override
  String get backupsRestoreConfirm => 'Restaurar';

  @override
  String get backupsRestored =>
      'Copia restaurada. Tus datos anteriores se guardaron como copia pre-restauración.';

  @override
  String backupsOperationFailed(String error) {
    return 'La operación falló: $error';
  }

  @override
  String get dataControlBusy => 'Espera a que Axi termine antes de hacer esto.';

  @override
  String get sectionDangerZone => 'Zona de peligro';

  @override
  String get wipeNavTitle => 'Borrar todos mis datos';

  @override
  String get wipeNavSubtitle =>
      'Elimina tus datos en este dispositivo. Los modelos y ajustes se conservan.';

  @override
  String get wipeTitle => 'Borrar todos mis datos';

  @override
  String get wipeDeletesTitle => 'Esto se eliminará';

  @override
  String get wipeDeletesBody =>
      '• Tu grafo de memoria (hechos, personas, conversaciones, vectores)\n• El historial del chat\n• Las notas de voz guardadas en este dispositivo\n• Tu último boletín, su horario y sus fuentes\n• Los recordatorios y sus alarmas programadas';

  @override
  String get wipeKeepsTitle => 'Esto se conserva';

  @override
  String get wipeKeepsBody =>
      '• Los modelos descargados (chat, voz, embeddings)\n• Los ajustes de la app (idioma, tema, onboarding)';

  @override
  String get wipeBackupFirst => 'Crear una copia antes de borrar';

  @override
  String wipeTypePrompt(String word) {
    return 'Escribe $word para confirmar';
  }

  @override
  String wipeCountdownButton(int seconds) {
    return 'Borrar ($seconds)';
  }

  @override
  String get wipeConfirmButton => 'Borrar todo';

  @override
  String get wipeInProgress => 'Borrando…';

  @override
  String get wipeDone => 'Se borraron todos tus datos en este dispositivo.';

  @override
  String wipePartialFailure(String targets) {
    return 'Algunos datos no se pudieron borrar: $targets';
  }

  @override
  String get sectionSecurity => 'Seguridad';

  @override
  String get appLockNavTitle => 'Bloqueo con huella o rostro';

  @override
  String get appLockNavSubtitle => 'Pide tu huella o rostro para abrir la app';

  @override
  String get appLockLockedTitle => 'LifeOS está bloqueado';

  @override
  String get appLockLockedBody =>
      'Tus datos están protegidos en este dispositivo. Verifica tu identidad para continuar.';

  @override
  String get appLockUnlockButton => 'Desbloquear';

  @override
  String get appLockUnavailableBody =>
      'Este dispositivo ya no puede verificar tu identidad (sin huella, rostro ni PIN configurados). Desactiva el bloqueo para entrar.';

  @override
  String get appLockDisableButton => 'Desactivar bloqueo';

  @override
  String get appLockEnableFailed =>
      'No se pudo verificar. El bloqueo sigue desactivado.';

  @override
  String get appLockUnavailableToast =>
      'Configura una huella, rostro o PIN en tu dispositivo para activar el bloqueo.';

  @override
  String get autostartNavTitle => 'Iniciar LifeOS al entrar a la sesión';

  @override
  String get autostartNavSubtitle =>
      'Se abre en segundo plano, en la barra del sistema, sin ventana';

  @override
  String get trayTooltip => 'LifeOS está funcionando';

  @override
  String get trayMenuShowWindow => 'Abrir LifeOS';

  @override
  String get trayMenuQuit => 'Salir de LifeOS';

  @override
  String get trayUnavailableTitle => 'Sin icono en la barra del sistema';

  @override
  String trayUnavailableMessage(String details) {
    return 'No se pudo poner el icono de LifeOS en la barra del sistema. La app sigue funcionando y la ventana se cierra como siempre. Detalle: $details';
  }
}
