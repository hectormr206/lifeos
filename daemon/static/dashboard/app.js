// LifeOS Dashboard — API client, SSE listener, diagnostics, UI logic
'use strict';

// --- Token management ---
const params = new URLSearchParams(location.search);
const bootMode = params.get('boot') === '1';
let token = params.get('token') || sessionStorage.getItem('lifeos_token') || '';
if (token) sessionStorage.setItem('lifeos_token', token);

const API = '/api/v1';
let feedCount = 0;
const MAX_FEED = 100;

function apiHeaders() {
  const next = { 'Content-Type': 'application/json' };
  if (token) next['x-bootstrap-token'] = token;
  return next;
}

// --- DOM refs ---
const $ = (sel) => document.querySelector(sel);
const orb = $('#axi-orb');
const stateLabel = $('#axi-state-label');
const stateReason = $('#axi-reason');
const feedbackBar = $('#feedback-bar');
const feedbackStage = $('#feedback-stage');
const feedbackTps = $('#feedback-tps');
const connectionBadge = $('#connection-badge');
const activityFeed = $('#activity-feed');
const feedCountEl = $('#feed-count');
const heroSummary = $('#hero-summary');
const heroMode = $('#hero-mode');
const heroConnection = $('#hero-connection');
const heroContext = $('#hero-context');
const heroLastEvent = $('#hero-last-event');
const heroChipState = $('#hero-chip-state');
const heroChipSensors = $('#hero-chip-sensors');
const heroChipMeeting = $('#hero-chip-meeting');
const heroChipPresence = $('#hero-chip-presence');
const heroTelemetryAudio = $('#hero-telemetry-audio');
const heroTelemetryScreen = $('#hero-telemetry-screen');
const heroTelemetryCamera = $('#hero-telemetry-camera');
const heroTelemetryWakeword = $('#hero-telemetry-wakeword');
const bootSequence = $('#boot-sequence');

const dashboardState = {
  axiState: 'offline',
  axiReason: '',
  connected: false,
  overlay: null,
  runtime: null,
  alwaysOn: null,
  context: null,
  presence: null,
  voice: null,
  meeting: null,
  lastSignal: '',
  lastSignalAt: null,
  bootMode,
};

// --- Aura map ---
const AURA_MAP = {
  idle: 'aura-green', listening: 'aura-cyan', thinking: 'aura-yellow',
  speaking: 'aura-blue', watching: 'aura-teal', error: 'aura-red',
  offline: 'aura-gray', night: 'aura-indigo',
};
const STATE_LABELS = {
  idle: 'En espera', listening: 'Escuchando...', thinking: 'Pensando...',
  speaking: 'Hablando...', watching: 'Observando...', error: 'Error',
  offline: 'Desconectado', night: 'Modo nocturno',
};

// --- Helpers ---
function timeAgo(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  const now = Date.now();
  const sec = Math.floor((now - d.getTime()) / 1000);
  if (sec < 0) return d.toLocaleTimeString('es');
  if (sec < 60) return `hace ${sec}s`;
  if (sec < 3600) return `hace ${Math.floor(sec / 60)} min`;
  if (sec < 86400) return `hace ${Math.floor(sec / 3600)}h`;
  return d.toLocaleDateString('es');
}

function yn(val) { return val ? 'Si' : 'No'; }
function ynClass(val) { return val ? 'val-ok' : 'val-error'; }
function setVal(id, text, cls) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text || '—';
  el.className = 'diag-value' + (cls ? ' ' + cls : '');
}

function setHeroChip(el, text, state) {
  if (!el) return;
  el.textContent = text || '—';
  el.className = 'hero-chip ' + (state || 'chip-neutral');
}

function formatStateLabel(state) {
  const key = (state || 'offline').toLowerCase();
  return STATE_LABELS[key] || key;
}

function formatContext(context) {
  if (!context) return 'Sin foco';
  const parts = [];
  if (context.current_application) parts.push(context.current_application);
  if (context.current_window) parts.push(context.current_window);
  return parts.join(' · ') || 'Sin foco';
}

function formatSignalLine() {
  if (!dashboardState.lastSignal) return 'Sin eventos recientes';
  const age = dashboardState.lastSignalAt ? ` · ${timeAgo(dashboardState.lastSignalAt)}` : '';
  return `${dashboardState.lastSignal}${age}`;
}

function buildSummaryText() {
  const parts = [];
  const stateLabel = formatStateLabel(dashboardState.axiState).toLowerCase();
  const sensory = diagCache.sensory || {};
  const cap = sensory.capabilities || {};
  const runtime = dashboardState.runtime || {};
  const presence = dashboardState.presence || {};
  const meeting = dashboardState.meeting || {};
  const context = dashboardState.context || {};
  const voice = dashboardState.voice || {};
  const stt = diagCache.stt || {};

  if (dashboardState.connected) {
    parts.push(`Axi esta ${stateLabel}.`);
  } else {
    parts.push('Axi esta esperando conexion segura.');
  }

  const activeSensors = [];
  if (runtime.audio_enabled) activeSensors.push('audio');
  if (runtime.screen_enabled) activeSensors.push('pantalla');
  if (runtime.camera_enabled) activeSensors.push('camara');
  if (activeSensors.length) parts.push(`Sensores activos: ${activeSensors.join(', ')}.`);

  const readiness = [];
  if (cap.stt_binary && stt.running) readiness.push('voz lista');
  if (cap.screen_capture_available && sensory.vision?.enabled) readiness.push('vision activa');
  if (cap.camera_capture_binary && presence.camera_active) readiness.push('camara activa');
  if (readiness.length) parts.push(`Estado AI: ${readiness.join(' · ')}.`);

  if (meeting.active) {
    parts.push(`Reunion detectada en ${meeting.conferencing_app || 'una app de videollamada'}.`);
  }

  if (presence.present != null) {
    parts.push(presence.present ? 'Presencia confirmada.' : 'Sin presencia detectada.');
  }

  if (context.current_application || context.current_window) {
    parts.push(`Contexto actual: ${formatContext(context)}.`);
  }

  if (voice.last_transcript) {
    parts.push(`Ultimo comando: ${voice.last_transcript}.`);
  }

  if (dashboardState.lastSignal) {
    parts.push(`Ultima señal: ${dashboardState.lastSignal}.`);
  }

  return parts.join(' ');
}

function renderHero() {
  if (heroSummary) heroSummary.textContent = buildSummaryText();
  if (heroMode) heroMode.textContent = formatStateLabel(dashboardState.axiState);
  if (heroConnection) heroConnection.textContent = dashboardState.connected ? 'Conectado' : 'Desconectado';
  if (heroContext) heroContext.textContent = formatContext(dashboardState.context);
  if (heroLastEvent) heroLastEvent.textContent = formatSignalLine();

  const sensory = diagCache.sensory || {};
  const cap = sensory.capabilities || {};
  const runtime = dashboardState.runtime || {};
  const presence = dashboardState.presence || {};
  const meeting = dashboardState.meeting || {};
  const voice = dashboardState.voice || {};
  const stt = diagCache.stt || {};

  const activeSensors = [runtime.audio_enabled, runtime.screen_enabled, runtime.camera_enabled].filter(Boolean).length;
  const sensorText = activeSensors
    ? `${activeSensors} activo${activeSensors === 1 ? '' : 's'}`
    : 'Sin sensores activos';
  const sensorState = activeSensors ? (activeSensors === 3 ? 'chip-ok' : 'chip-warn') : 'chip-error';
  setHeroChip(heroChipState, formatStateLabel(dashboardState.axiState), {
    offline: 'chip-error',
    error: 'chip-error',
    listening: 'chip-ok',
    speaking: 'chip-ok',
    watching: 'chip-warn',
    thinking: 'chip-warn',
    idle: 'chip-ok',
    night: 'chip-neutral',
  }[dashboardState.axiState] || 'chip-neutral');
  setHeroChip(heroChipSensors, sensorText, sensorState);
  setHeroChip(heroChipMeeting, meeting.active ? `Reunion: ${meeting.conferencing_app || 'activa'}` : 'Reunion: No', meeting.active ? 'chip-warn' : 'chip-neutral');
  setHeroChip(heroChipPresence, presence.present == null ? 'Presencia: Sin datos' : presence.present ? 'Presencia: Detectada' : 'Presencia: Ausente', presence.present == null ? 'chip-neutral' : presence.present ? 'chip-ok' : 'chip-warn');

  if (heroTelemetryAudio) {
    const audioOk = !!(cap.stt_binary && stt.running);
    heroTelemetryAudio.textContent = runtime.audio_enabled ? (audioOk ? 'STT listo' : 'Audio activo') : 'Inactivo';
  }
  if (heroTelemetryScreen) {
    heroTelemetryScreen.textContent = runtime.screen_enabled
      ? (sensory.vision?.enabled ? 'Vision activa' : 'Captura armada')
      : 'Inactiva';
  }
  if (heroTelemetryCamera) {
    heroTelemetryCamera.textContent = runtime.camera_enabled
      ? (presence.camera_active ? 'Analizando' : 'Armada')
      : 'Inactiva';
  }
  if (heroTelemetryWakeword) {
    heroTelemetryWakeword.textContent = voice.wake_word || 'axi';
  }
}

function trackSignal(text) {
  dashboardState.lastSignal = text || '';
  dashboardState.lastSignalAt = new Date().toISOString();
  renderHero();
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function openSensorCard(sensor) {
  const card = document.querySelector(`.control-card[data-sensor="${sensor}"]`);
  const header = card?.querySelector('.control-header.clickable');
  if (!card || !header) return;
  const wasExpanded = card.classList.contains('expanded');
  document.querySelectorAll('.control-card.expanded').forEach(c => c.classList.remove('expanded'));
  if (!wasExpanded) card.classList.add('expanded');
  card.scrollIntoView({ behavior: 'smooth', block: 'center' });
  if (!wasExpanded) refreshDiagPanel(sensor).catch(() => {});
}

// --- API helpers ---
async function api(method, path, body) {
  const opts = { method, headers: apiHeaders() };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(API + path, opts);
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.message || res.statusText);
  }
  return res.json();
}

async function ensureBootstrapToken() {
  if (token) return token;
  try {
    const res = await fetch('/dashboard/bootstrap');
    if (!res.ok) return '';
    const data = await res.json().catch(() => ({}));
    if (data?.token) {
      token = data.token;
      sessionStorage.setItem('lifeos_token', token);
      return token;
    }
  } catch (err) {
    console.warn('Bootstrap token fetch failed:', err);
  }
  return '';
}

// --- Update UI from state ---
function updateOrb(state, aura, reason) {
  const key = (state || 'offline').toLowerCase();
  dashboardState.axiState = key;
  dashboardState.axiReason = reason || '';
  orb.className = 'orb ' + (AURA_MAP[key] || 'aura-gray');
  stateLabel.textContent = STATE_LABELS[key] || key;
  if (reason !== undefined) stateReason.textContent = reason || '';
  renderHero();
}

function updateOverlayDetails(overlay) {
  if (!overlay) return;
  dashboardState.overlay = overlay;
  const widgetVisible = overlay.widget_visible !== false;
  $('#toggle-widget').checked = widgetVisible;
  $('#widget-status').textContent = widgetVisible ? 'Visible' : 'Oculto';
  const note = document.getElementById('widget-note');
  if (note) {
    const parts = ['Arrastra la orb en el escritorio para moverla.'];
    if (overlay.widget_badge) parts.push(`Estado actual: ${overlay.widget_badge}.`);
    parts.push('Click abre este panel.');
    note.textContent = parts.join(' ');
  }
  renderHero();
}

function updateSensoryToggles(runtime) {
  dashboardState.runtime = runtime;
  $('#toggle-audio').checked = runtime.audio_enabled;
  $('#toggle-screen').checked = runtime.screen_enabled;
  $('#toggle-camera').checked = runtime.camera_enabled;
  $('#audio-status').textContent = runtime.audio_enabled ? 'Activo' : 'Inactivo';
  $('#screen-status').textContent = runtime.screen_enabled ? 'Activo' : 'Inactivo';
  $('#camera-status').textContent = runtime.camera_enabled ? 'Activo' : 'Inactivo';
  renderHero();
}

function updateAlwaysOn(ao) {
  dashboardState.alwaysOn = ao;
  $('#toggle-always-on').checked = ao.enabled;
  $('#always-on-status').textContent = ao.enabled ? 'Activo' : 'Inactivo';
  if (ao.wake_word) $('#wake-word-input').value = ao.wake_word;
  renderHero();
}

function updateContext(ctx) {
  dashboardState.context = ctx;
  $('#current-app').textContent = ctx.current_application || '—';
  $('#current-window').textContent = ctx.current_window || '—';
  renderHero();
}

function updatePresence(p) {
  if (!p) return;
  dashboardState.presence = p;
  $('#presence-status').textContent = p.present ? 'Presente' : 'Ausente';
  const details = [];
  if (p.user_state) details.push(p.user_state);
  if (p.people_count != null) details.push(p.people_count + ' persona(s)');
  $('#presence-detail').textContent = details.join(' · ') || '—';
  renderHero();
}

function updateVoice(voice) {
  if (!voice) return;
  dashboardState.voice = voice;
  $('#last-transcript').textContent = voice.last_transcript || '—';
  $('#last-response').textContent = voice.last_response
    ? voice.last_response.substring(0, 120) + (voice.last_response.length > 120 ? '...' : '')
    : '—';
  renderHero();
}

function updateMeeting(m) {
  if (!m) return;
  dashboardState.meeting = m;
  $('#meeting-status').textContent = m.active ? 'En reunion' : 'Sin reunion';
  $('#meeting-app').textContent = m.conferencing_app || '';
  renderHero();
}

// --- Activity feed ---
function addFeedItem(icon, text) {
  const now = new Date();
  const time = now.toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const item = document.createElement('div');
  item.className = 'feed-item';
  const timeSpan = document.createElement('span');
  timeSpan.className = 'feed-time';
  timeSpan.textContent = time;
  const iconSpan = document.createElement('span');
  iconSpan.className = 'feed-icon';
  iconSpan.innerHTML = icon; // safe: icon is always a static HTML entity from our code
  const textSpan = document.createElement('span');
  textSpan.className = 'feed-text';
  textSpan.textContent = text; // textContent prevents XSS from event data
  item.append(timeSpan, iconSpan, textSpan);
  activityFeed.prepend(item);
  feedCount++;
  feedCountEl.textContent = feedCount;
  trackSignal(text);
  while (activityFeed.children.length > MAX_FEED) {
    activityFeed.removeChild(activityFeed.lastChild);
  }
}

// --- SSE connection ---
function connectSSE() {
  const url = `${API}/events/stream?token=${encodeURIComponent(token)}`;
  const sse = new EventSource(url);

  sse.onopen = () => {
    dashboardState.connected = true;
    connectionBadge.textContent = 'Conectado';
    connectionBadge.className = 'badge badge-online';
    renderHero();
  };

  sse.onerror = (e) => {
    if (sse.readyState === EventSource.CLOSED) {
      dashboardState.connected = false;
      connectionBadge.textContent = 'Desconectado';
      connectionBadge.className = 'badge badge-offline';
      renderHero();
    } else if (sse.readyState === EventSource.CONNECTING) {
      connectionBadge.textContent = 'Reconectando...';
      connectionBadge.className = 'badge badge-warn';
      renderHero();
    }
  };

  sse.onmessage = (e) => {
    if (!e.data || e.data === 'ping') return;
    let event;
    try { event = JSON.parse(e.data); } catch { return; }
    handleEvent(event);
  };

  return sse;
}

function handleEvent(event) {
  switch (event.type) {
    case 'axi_state_changed':
      updateOrb(event.data.state, event.data.aura, event.data.reason);
      addFeedItem('&#9679;', `Axi → ${event.data.state}`);
      break;
    case 'sensor_changed':
      dashboardState.runtime = {
        ...(dashboardState.runtime || {}),
        audio_enabled: event.data.mic,
        screen_enabled: event.data.screen,
        camera_enabled: event.data.camera,
      };
      $('#toggle-audio').checked = event.data.mic;
      $('#toggle-screen').checked = event.data.screen;
      $('#toggle-camera').checked = event.data.camera;
      $('#audio-status').textContent = event.data.mic ? 'Activo' : 'Inactivo';
      $('#screen-status').textContent = event.data.screen ? 'Activo' : 'Inactivo';
      $('#camera-status').textContent = event.data.camera ? 'Activo' : 'Inactivo';
      renderHero();
      if (event.data.kill_switch) addFeedItem('&#9888;', 'Kill switch activado');
      break;
    case 'feedback_update':
      dashboardState.lastSignal = `Feedback ${event.data.stage || 'actualizado'}`;
      dashboardState.lastSignalAt = new Date().toISOString();
      if (event.data.stage) {
        feedbackBar.classList.remove('hidden');
        feedbackStage.textContent = event.data.stage;
        feedbackTps.textContent = event.data.tokens_per_second
          ? `${event.data.tokens_per_second.toFixed(1)} tok/s` : '';
      } else {
        feedbackBar.classList.add('hidden');
      }
      renderHero();
      break;
    case 'window_changed':
      dashboardState.context = {
        ...(dashboardState.context || {}),
        current_application: event.data.app || dashboardState.context?.current_application || '',
        current_window: event.data.title || dashboardState.context?.current_window || '',
      };
      $('#current-app').textContent = event.data.app || '—';
      $('#current-window').textContent = event.data.title || '—';
      addFeedItem('&#128421;', `${event.data.app}: ${event.data.title}`);
      break;
    case 'wake_word_detected':
      addFeedItem('&#127908;', `Wake word "${event.data.word}" detectado`);
      break;
    case 'voice_session_start':
      addFeedItem('&#128483;', 'Sesion de voz iniciada');
      break;
    case 'voice_session_end':
      dashboardState.voice = {
        ...(dashboardState.voice || {}),
        last_transcript: event.data.transcript || dashboardState.voice?.last_transcript || '',
        last_response: event.data.response || dashboardState.voice?.last_response || '',
      };
      if (event.data.transcript) {
        $('#last-transcript').textContent = event.data.transcript;
        addFeedItem('&#128172;', event.data.transcript);
      }
      if (event.data.response) {
        const short = event.data.response.substring(0, 80);
        $('#last-response').textContent = short;
      }
      renderHero();
      break;
    case 'screen_capture':
      addFeedItem('&#128247;', event.data.summary || 'Captura de pantalla');
      break;
    case 'meeting_state_changed':
      dashboardState.meeting = {
        ...(dashboardState.meeting || {}),
        active: !!event.data.active,
        conferencing_app: event.data.app || dashboardState.meeting?.conferencing_app || '',
      };
      $('#meeting-status').textContent = event.data.active ? 'En reunion' : 'Sin reunion';
      $('#meeting-app').textContent = event.data.app || '';
      addFeedItem('&#128222;', event.data.active
        ? `Reunion detectada (${event.data.app || '?'})` : 'Reunion finalizada');
      break;
    case 'presence_update':
      dashboardState.presence = {
        ...(dashboardState.presence || {}),
        present: event.data.present,
      };
      $('#presence-status').textContent = event.data.present ? 'Presente' : 'Ausente';
      renderHero();
      break;
    case 'notification':
      addFeedItem('&#128276;', `[${event.data.priority}] ${event.data.message}`);
      break;
  }
}

// ==================== DIAGNOSTICS ====================

// Cache for diagnostic data
let diagCache = { sensory: null, stt: null, lastFetch: 0 };

async function fetchDiagnostics() {
  const now = Date.now();
  if (diagCache.sensory && now - diagCache.lastFetch < 2000) return diagCache;
  try {
    const [sensory, stt] = await Promise.all([
      api('GET', '/sensory/status'),
      api('GET', '/audio/stt/status').catch(() => null),
    ]);
    diagCache = { sensory, stt, lastFetch: now };
    renderHero();
  } catch (e) {
    console.error('Diagnostics fetch failed:', e);
  }
  return diagCache;
}

function setDot(id, level) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = 'diag-dot ' + (level === 'ok' ? 'dot-ok' : level === 'warn' ? 'dot-warn' : 'dot-error');
}

// --- Populate each diagnostic panel ---

function populateAudioDiag(sensory, stt) {
  const cap = sensory?.capabilities || {};
  const voice = sensory?.voice || {};

  // Health
  const hasBinary = !!cap.stt_binary;
  const sttRunning = stt?.running || false;
  if (hasBinary && sttRunning) setDot('dot-audio', 'ok');
  else if (hasBinary) setDot('dot-audio', 'warn');
  else setDot('dot-audio', 'error');

  setVal('d-audio-stt', sttRunning ? 'Corriendo' : 'Detenido', sttRunning ? 'val-ok' : 'val-error');
  setVal('d-audio-binary', cap.stt_binary || 'No encontrado', cap.stt_binary ? '' : 'val-error');
  setVal('d-audio-capture', cap.audio_capture_binary || 'No encontrado', cap.audio_capture_binary ? '' : 'val-error');
  setVal('d-audio-transcript', voice.last_transcript || '(sin datos)');
  setVal('d-audio-latency', voice.last_latency_ms ? voice.last_latency_ms + 'ms' : '—');
  setVal('d-audio-tts', cap.tts_binary ? (cap.tts_binary + (cap.tts_model ? ' + modelo' : '')) : 'No encontrado', cap.tts_binary ? '' : 'val-warn');
  setVal('d-audio-last', timeAgo(voice.last_listen_at));

  // Error
  const errRow = document.getElementById('d-audio-error-row');
  const lastErr = sensory?.last_error;
  if (lastErr) {
    errRow?.classList.remove('hidden');
    setVal('d-audio-error', lastErr);
  } else {
    errRow?.classList.add('hidden');
  }
}

function populateAlwaysOnDiag(sensory) {
  const cap = sensory?.capabilities || {};
  const voice = sensory?.voice || {};

  const hasModel = cap.rustpotter_model_available || false;
  const active = voice.always_on_active || false;
  if (active) setDot('dot-always-on', 'ok');
  else if (hasModel || cap.always_on_source) setDot('dot-always-on', 'warn');
  else setDot('dot-always-on', 'error');

  setVal('d-ao-word', voice.wake_word || '—');
  setVal('d-ao-model', yn(hasModel), ynClass(hasModel));
  setVal('d-ao-source', cap.always_on_source || 'whisper-fallback');
  setVal('d-ao-active', yn(active), ynClass(active));
  setVal('d-ao-last-hotword', timeAgo(voice.last_hotword_at));
  setVal('d-ao-bargein', voice.barge_in_count != null ? String(voice.barge_in_count) : '—');

  const hint = document.getElementById('d-ao-hint-word');
  if (hint) hint.textContent = voice.wake_word || 'axi';
}

function populateScreenDiag(sensory) {
  const cap = sensory?.capabilities || {};
  const vision = sensory?.vision || {};

  const hasCapture = cap.screen_capture_available || false;
  const hasOcr = cap.tesseract_available || false;
  const hasMultimodal = cap.multimodal_chat_available || false;
  const enabled = vision.enabled || false;

  if (hasCapture && enabled) setDot('dot-screen', 'ok');
  else if (hasCapture) setDot('dot-screen', 'warn');
  else setDot('dot-screen', 'error');

  setVal('d-screen-available', yn(hasCapture), ynClass(hasCapture));
  setVal('d-screen-ocr', yn(hasOcr), ynClass(hasOcr));
  setVal('d-screen-multimodal', hasMultimodal ? (cap.llama_server_running ? 'Si (llama-server activo)' : 'Si (llama-server inactivo)') : 'No', hasMultimodal ? (cap.llama_server_running ? 'val-ok' : 'val-warn') : 'val-error');
  setVal('d-screen-app', (vision.current_app || '—') + (vision.current_window ? ' — ' + vision.current_window : ''));
  setVal('d-screen-summary', vision.last_summary ? vision.last_summary.substring(0, 200) : '(sin datos)');
  setVal('d-screen-ocrtext', vision.last_ocr_text ? vision.last_ocr_text.substring(0, 200) : '(sin datos)');
  setVal('d-screen-latency', vision.last_query_latency_ms ? vision.last_query_latency_ms + 'ms' : '—');
  setVal('d-screen-last', timeAgo(vision.last_updated_at));

  const errRow = document.getElementById('d-screen-error-row');
  if (vision.last_multimodal_success === false && hasMultimodal) {
    errRow?.classList.remove('hidden');
    setVal('d-screen-error', 'Ultima consulta multimodal fallo');
  } else {
    errRow?.classList.add('hidden');
  }
}

function populateCameraDiag(sensory) {
  const cap = sensory?.capabilities || {};
  const presence = sensory?.presence || {};
  const meeting = sensory?.meeting || {};

  const available = presence.camera_available || false;
  const consented = presence.camera_consented || false;
  const active = presence.camera_active || false;

  if (available && active) setDot('dot-camera', 'ok');
  else if (available && consented) setDot('dot-camera', 'warn');
  else setDot('dot-camera', 'error');

  setVal('d-cam-device', cap.camera_device || 'No detectado', cap.camera_device ? '' : 'val-error');
  setVal('d-cam-binary', cap.camera_capture_binary || 'No encontrado', cap.camera_capture_binary ? '' : 'val-error');
  setVal('d-cam-available', yn(available), ynClass(available));
  setVal('d-cam-consent', yn(consented), ynClass(consented));
  setVal('d-cam-meeting', meeting.active ? (meeting.conferencing_app || 'Si') : 'No');
  setVal('d-cam-busy', yn(meeting.camera_busy), meeting.camera_busy ? 'val-warn' : '');
  setVal('d-cam-userstate', presence.user_state || '—');
  setVal('d-cam-people', presence.people_count != null ? String(presence.people_count) : '—');
  setVal('d-cam-scene', presence.scene_description || '(sin datos)');
  setVal('d-cam-last', timeAgo(presence.last_seen_at || presence.last_checked_at));

  const fatigueRow = document.getElementById('d-cam-fatigue-row');
  const postureRow = document.getElementById('d-cam-posture-row');
  if (presence.fatigue_alert) fatigueRow?.classList.remove('hidden');
  else fatigueRow?.classList.add('hidden');
  if (presence.posture_alert) postureRow?.classList.remove('hidden');
  else postureRow?.classList.add('hidden');
}

async function refreshDiagPanel(sensor) {
  const { sensory, stt } = await fetchDiagnostics();
  if (!sensory) return;

  switch (sensor) {
    case 'audio': populateAudioDiag(sensory, stt); break;
    case 'always-on': populateAlwaysOnDiag(sensory); break;
    case 'screen': populateScreenDiag(sensory); break;
    case 'camera': populateCameraDiag(sensory); break;
  }
}

// --- Panel toggle ---
document.querySelectorAll('.control-header.clickable').forEach(header => {
  header.addEventListener('click', async () => {
    const card = header.closest('.control-card');
    const wasExpanded = card.classList.contains('expanded');

    // Close all panels
    document.querySelectorAll('.control-card.expanded').forEach(c => c.classList.remove('expanded'));

    if (!wasExpanded) {
      card.classList.add('expanded');
      await refreshDiagPanel(card.dataset.sensor);
    }
  });
});

// --- Auto-refresh open panels ---
setInterval(() => {
  const expanded = document.querySelector('.control-card.expanded');
  if (expanded) refreshDiagPanel(expanded.dataset.sensor);
}, 5000);

document.querySelectorAll('[data-quick-action]').forEach(btn => {
  btn.addEventListener('click', async () => {
    switch (btn.dataset.quickAction) {
      case 'open-controls':
        document.querySelector('.controls-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
        break;
      case 'focus-audio':
        openSensorCard('audio');
        break;
      case 'run-audio-test':
        document.querySelector('.diag-test-btn[data-test="audio"]')?.click();
        break;
      case 'run-screen-test':
        document.querySelector('.diag-test-btn[data-test="screen"]')?.click();
        break;
      case 'refresh-state':
        await refreshFullState();
        break;
      case 'refresh-tasks':
        await refreshSupervisor();
        await refreshTasks();
        break;
      case 'trigger-heartbeat':
        await fetch(`${API}/supervisor/status`, { headers: apiHeaders() });
        btn.textContent = 'Enviado';
        setTimeout(() => { btn.textContent = 'Heartbeat manual'; }, 2000);
        break;
    }
  });
});

let bootSequenceRan = false;
async function runWelcomeSequence() {
  if (!bootMode || bootSequenceRan || !bootSequence) return;
  if (!dashboardState.connected) return; // skip cinematic if daemon is unreachable
  bootSequenceRan = true;

  const steps = [
    'Boot solicitado. Despertando Axi...',
    'Sincronizando telemetria segura...',
    'Leyendo audio, pantalla y presencia...',
    'Listo. El panel ya esta operativo.',
  ];

  bootSequence.classList.remove('hidden');
  for (const step of steps) {
    bootSequence.textContent = step;
    addFeedItem('&#9889;', step);
    await delay(step.endsWith('...') ? 850 : 1100);
  }
  await delay(600);
  bootSequence.classList.add('hidden');
}

// --- Test buttons ---
async function runSensorTest(sensor) {
  switch (sensor) {
    case 'audio':
      return await api('POST', '/sensory/voice/session', { playback: false, include_screen: false });
    case 'screen':
      return await api('POST', '/runtime/sensory/snapshot', { include_screen: true });
    case 'camera':
      return await api('POST', '/runtime/sensory/snapshot', {});
    default:
      throw new Error('No hay prueba para este sensor');
  }
}

document.querySelectorAll('.diag-test-btn').forEach(btn => {
  btn.addEventListener('click', async (e) => {
    e.stopPropagation();
    const sensor = btn.dataset.test;
    const resultEl = document.getElementById('test-result-' + sensor);
    btn.disabled = true;
    btn.textContent = 'Probando...';
    btn.className = 'diag-test-btn';
    if (resultEl) resultEl.textContent = '';

    try {
      const result = await runSensorTest(sensor);
      btn.textContent = 'OK';
      btn.classList.add('test-ok');
      if (resultEl) {
        if (result.snapshot?.transcript) resultEl.textContent = 'Texto: ' + result.snapshot.transcript;
        else if (result.snapshot?.screen_path) resultEl.textContent = 'Captura: ' + result.snapshot.screen_path;
        else resultEl.textContent = 'Prueba completada';
      }
      addFeedItem('&#9989;', `Prueba ${sensor}: OK`);
      // Refresh the panel data
      setTimeout(() => refreshDiagPanel(sensor), 500);
    } catch (err) {
      btn.textContent = 'Error';
      btn.classList.add('test-fail');
      if (resultEl) resultEl.textContent = err.message;
      addFeedItem('&#10060;', `Prueba ${sensor}: ${err.message}`);
    } finally {
      btn.disabled = false;
      setTimeout(() => {
        const labels = { audio: '\u25B6 Probar Oido', screen: '\uD83D\uDCF7 Capturar Pantalla', camera: '\uD83D\uDCF7 Capturar Camara' };
        btn.textContent = labels[sensor] || 'Probar';
        btn.className = 'diag-test-btn';
      }, 4000);
    }
  });
});

// ==================== CONTROL ACTIONS ====================

async function ensureConsent() {
  try { await api('POST', '/followalong/consent', { granted: true }); }
  catch (e) { console.warn('consent grant failed:', e); }
}

async function toggleSensory(field, value, elId) {
  try {
    await ensureConsent();
    const current = await api('GET', '/runtime/sensory');
    const body = {
      enabled: current.enabled !== false,
      audio_enabled: current.audio_enabled,
      screen_enabled: current.screen_enabled,
      camera_enabled: current.camera_enabled,
    };
    body[field] = value;
    // If enabling any sensor, ensure the master enabled flag is on
    if (value && field !== 'capture_interval_seconds') body.enabled = true;
    await api('POST', '/runtime/sensory', body);
    
    // Refresh panel immediately if expanded to show state
    const expanded = document.querySelector('.control-card.expanded');
    if (expanded) refreshDiagPanel(expanded.dataset.sensor);
  } catch (err) {
    if (elId) {
      const el = $(`#${elId}`);
      if (el) el.checked = !value;
    }
    addFeedItem('&#10060;', `Error toggle ${field}: ${err.message}`);
  }
}

$('#toggle-audio').addEventListener('change', (e) => toggleSensory('audio_enabled', e.target.checked, 'toggle-audio'));
$('#toggle-screen').addEventListener('change', (e) => toggleSensory('screen_enabled', e.target.checked, 'toggle-screen'));
$('#toggle-camera').addEventListener('change', (e) => toggleSensory('camera_enabled', e.target.checked, 'toggle-camera'));

$('#toggle-always-on').addEventListener('change', async (e) => {
  try { await api('POST', '/runtime/always-on', { enabled: e.target.checked }); }
  catch (err) { 
    e.target.checked = !e.target.checked;
    addFeedItem('&#10060;', `Error toggle always-on: ${err.message}`); 
  }
});

$('#toggle-widget').addEventListener('change', async (e) => {
  try {
    await api('POST', '/overlay/config', { widget_visible: e.target.checked });
    $('#widget-status').textContent = e.target.checked ? 'Visible' : 'Oculto';
  } catch (err) {
    e.target.checked = !e.target.checked;
    addFeedItem('&#10060;', `Error widget flotante: ${err.message}`);
  }
});

$('#kill-switch').addEventListener('click', async () => {
  if (!confirm('Desactivar TODOS los sentidos?')) return;
  await api('POST', '/sensory/kill-switch', { actor: 'dashboard' });
  addFeedItem('&#9888;', 'KILL SWITCH activado desde el dashboard');
});

$('#wake-word-save').addEventListener('click', async (e) => {
  const btn = e.target;
  const word = $('#wake-word-input').value.trim();
  if (word) {
    btn.textContent = '...';
    try {
      await api('POST', '/runtime/always-on', { enabled: true, wake_word: word });
      btn.textContent = '¡Guardado!';
      btn.style.background = 'var(--success)';
    } catch (err) {
      btn.textContent = 'Error';
      btn.style.background = 'var(--danger)';
    } finally {
      setTimeout(() => { btn.textContent = 'Guardar'; btn.style.background = ''; }, 2000);
    }
  }
});

// --- Wake word training ---
async function wwRefresh() {
  try {
    const data = await api('GET', '/sensory/wake-word/samples');
    const count = data.count || 0;
    const modelExists = data.model_exists || false;
    $('#ww-status').textContent = `${count} muestra(s)` + (modelExists ? ' | Modelo listo' : ' | Sin modelo');
    $('#ww-status').style.color = modelExists ? 'var(--success)' : '#aaa';
    $('#ww-train').disabled = count < 3;
    const list = (data.samples || []).map(s => s.name).join(', ');
    $('#ww-samples').textContent = list || '';
  } catch { $('#ww-status').textContent = 'Error cargando'; }
}

$('#ww-record').addEventListener('click', async () => {
  const btn = $('#ww-record');
  btn.disabled = true;
  btn.textContent = 'Grabando...';
  btn.style.background = '#c0392b';
  try {
    await api('POST', '/sensory/wake-word/record');
    btn.textContent = 'Grabado!';
    btn.style.background = '#27ae60';
    await wwRefresh();
  } catch (err) {
    btn.textContent = 'Error';
  } finally {
    setTimeout(() => { btn.textContent = 'Grabar muestra (2.5s)'; btn.style.background = '#e74c3c'; btn.disabled = false; }, 1500);
  }
});

$('#ww-train').addEventListener('click', async () => {
  const btn = $('#ww-train');
  btn.disabled = true;
  btn.textContent = 'Entrenando...';
  try {
    const result = await api('POST', '/sensory/wake-word/train');
    btn.textContent = 'Modelo creado!';
    btn.style.background = '#27ae60';
    $('#ww-status').textContent = 'Modelo listo. Reinicia el daemon para activar.';
    $('#ww-status').style.color = 'var(--success)';
  } catch (err) {
    btn.textContent = 'Error';
    btn.style.background = '#e74c3c';
    $('#ww-status').textContent = err.message || 'Error entrenando';
  } finally {
    setTimeout(() => { btn.textContent = 'Entrenar modelo'; btn.style.background = '#27ae60'; btn.disabled = false; }, 3000);
  }
});

$('#ww-delete').addEventListener('click', async () => {
  if (!confirm('Borrar todas las muestras de wake word?')) return;
  await api('DELETE', '/sensory/wake-word/samples');
  await wwRefresh();
});

wwRefresh();

$('#interval-slider').addEventListener('input', (e) => {
  $('#interval-value').textContent = e.target.value + 's';
});
$('#interval-slider').addEventListener('change', async (e) => {
  await toggleSensory('capture_interval_seconds', parseInt(e.target.value));
});

// --- Theme toggle ---
$('#theme-toggle').addEventListener('click', () => {
  const html = document.documentElement;
  const next = html.dataset.theme === 'dark' ? 'light' : 'dark';
  html.dataset.theme = next;
  localStorage.setItem('lifeos-theme', next);
});
const savedTheme = localStorage.getItem('lifeos-theme');
if (savedTheme) document.documentElement.dataset.theme = savedTheme;

// ==================== INITIAL FETCH ====================

async function fetchInitialState() {
  try {
    await ensureBootstrapToken();
    const [overlay, sensory, runtime, alwaysOn, context] = await Promise.all([
      api('GET', '/overlay/status'),
      api('GET', '/sensory/status'),
      api('GET', '/runtime/sensory'),
      api('GET', '/runtime/always-on'),
      api('GET', '/followalong/context'),
    ]);

    if (overlay.axi_state) updateOrb(overlay.axi_state, null, overlay.reason || overlay.state_reason || overlay.axi_reason || '');
    updateOverlayDetails(overlay);
    if (runtime) updateSensoryToggles(runtime);
    if (alwaysOn) updateAlwaysOn(alwaysOn);
    if (context) updateContext(context);

    if (sensory) {
      diagCache = { sensory, stt: null, lastFetch: Date.now() };
      updateVoice(sensory.voice);
      updatePresence(sensory.presence);
      updateMeeting(sensory.meeting);
      if (sensory.vision && sensory.vision.capture_interval_seconds) {
        $('#interval-slider').value = sensory.vision.capture_interval_seconds;
        $('#interval-value').textContent = sensory.vision.capture_interval_seconds + 's';
      }
      // Update all health dots from initial data
      populateAudioDiag(sensory, null);
      populateAlwaysOnDiag(sensory);
      populateScreenDiag(sensory);
      populateCameraDiag(sensory);
    }

    // Fetch STT status separately
    api('GET', '/audio/stt/status').then(stt => {
      diagCache.stt = stt;
      populateAudioDiag(diagCache.sensory, stt);
      renderHero();
    }).catch(() => {});

    dashboardState.connected = true;
    connectionBadge.textContent = 'Conectado';
    connectionBadge.className = 'badge badge-online';
    
    searchMemory(''); // Populate memory pane initially
    renderHero();
  } catch (err) {
    console.error('Failed to fetch initial state:', err);
    dashboardState.connected = false;
    addFeedItem('&#9888;', 'Error al cargar estado inicial: ' + err.message);
    renderHero();
  }
}

// --- Periodic full state refresh (catch anything SSE missed) ---
async function refreshFullState() {
  try {
    await ensureBootstrapToken();
    const [overlay, sensory, runtime, alwaysOn, context] = await Promise.all([
      api('GET', '/overlay/status'),
      api('GET', '/sensory/status'),
      api('GET', '/runtime/sensory'),
      api('GET', '/runtime/always-on'),
      api('GET', '/followalong/context'),
    ]);

    if (overlay?.axi_state) updateOrb(overlay.axi_state, null, overlay.reason || overlay.state_reason || overlay.axi_reason || '');
    updateOverlayDetails(overlay);
    if (runtime) updateSensoryToggles(runtime);
    if (alwaysOn) updateAlwaysOn(alwaysOn);
    if (context) updateContext(context);

    if (sensory) {
      diagCache = { sensory, stt: diagCache.stt, lastFetch: Date.now() };
      updateVoice(sensory.voice);
      updatePresence(sensory.presence);
      updateMeeting(sensory.meeting);

      // Refresh expanded diagnostic panel
      const expanded = document.querySelector('.control-card.expanded');
      if (expanded) {
        const sensor = expanded.dataset.sensor;
        switch (sensor) {
          case 'audio': populateAudioDiag(sensory, diagCache.stt); break;
          case 'always-on': populateAlwaysOnDiag(sensory); break;
          case 'screen': populateScreenDiag(sensory); break;
          case 'camera': populateCameraDiag(sensory); break;
        }
      }
      // Always update health dots
      populateAudioDiag(sensory, diagCache.stt);
      populateAlwaysOnDiag(sensory);
      populateScreenDiag(sensory);
      populateCameraDiag(sensory);
      renderHero();
    }
  } catch (e) {
    console.warn('periodic refresh failed:', e);
  }
}

setInterval(refreshFullState, 3000);

// --- Supervisor & Task Queue ---
const svBadge = $('#supervisor-badge');
const svPending = $('#sv-pending');
const svRunning = $('#sv-running');
const svCompleted = $('#sv-completed');
const svFailed = $('#sv-failed');
const taskListEl = $('#task-list');

async function refreshSupervisor() {
  try {
    const res = await fetch(`${API}/supervisor/status`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();

    if (svBadge) {
      svBadge.textContent = data.running ? 'Activo' : 'Detenido';
      svBadge.className = data.running ? 'badge badge-ok' : 'badge badge-offline';
    }
    const q = data.queue || {};
    if (svPending) svPending.textContent = q.pending || 0;
    if (svRunning) svRunning.textContent = q.running || 0;
    if (svCompleted) svCompleted.textContent = q.completed || 0;
    if (svFailed) svFailed.textContent = q.failed || 0;
  } catch (e) {
    console.warn('supervisor status fetch failed:', e);
  }
}

async function refreshTasks() {
  try {
    const res = await fetch(`${API}/tasks?limit=10`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();

    if (!taskListEl) return;
    if (!data.tasks || data.tasks.length === 0) {
      taskListEl.innerHTML = '<p class="task-empty">Sin tareas recientes</p>';
      return;
    }

    taskListEl.innerHTML = data.tasks.map(t => {
      const statusIcon = {
        completed: '\u2705', running: '\u23F3', failed: '\u274C',
        pending: '\u23F1', retrying: '\u{1F504}', cancelled: '\u26D4'
      }[t.status] || '\u2753';
      const result = t.result
        ? `<div class="task-result">${escapeHtml(t.result.substring(0, 500))}</div>`
        : '';
      return `<div class="task-item" data-status="${t.status}">
        <div>
          <div class="task-objective">${statusIcon} ${escapeHtml(t.objective.substring(0, 120))}</div>
          <div class="task-meta">${t.status} \u00B7 ${t.source} \u00B7 ${t.updated_at?.substring(0, 19) || ''}</div>
          ${result}
        </div>
      </div>`;
    }).join('');
  } catch (e) {
    console.warn('tasks fetch failed:', e);
  }
}

function escapeHtml(s) {
  if (!s) return '';
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}



// --- Chat with Axi ---
const chatMessages = $('#chat-messages');
const chatForm = $('#chat-form');
const chatInput = $('#chat-input');

if (chatForm) {
  chatForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const text = chatInput.value.trim();
    if (!text) return;
    chatInput.value = '';

    // Add user message
    appendChat('user', text);

    // Check for /do command
    if (text.startsWith('/do ') || text.startsWith('/task ')) {
      const objective = text.replace(/^\/(do|task)\s+/, '');
      try {
        const res = await fetch(`${API}/tasks`, {
          method: 'POST', headers: apiHeaders(),
          body: JSON.stringify({ objective, source: 'dashboard' })
        });
        if (res.ok) {
          const task = await res.json();
          appendChat('axi', `Tarea creada: ${objective}\nID: ${task.id}\nEl supervisor la ejecutara.`);
          refreshTasks(); // Update UI immediately
          refreshSupervisor(); // Update UI immediately
        } else {
          appendChat('axi', 'Error al crear tarea.');
        }
      } catch (err) {
        appendChat('axi', `Error: ${err.message}`);
      }
      return;
    }

    // Regular chat via LLM router
    try {
      appendChat('axi', '...');
      const res = await fetch(`${API}/llm/chat`, {
        method: 'POST', headers: apiHeaders(),
        body: JSON.stringify({ messages: [{ role: 'user', content: text }] })
      });
      // Remove typing indicator
      const typing = chatMessages.querySelector('.chat-msg-axi:last-child');
      if (typing && typing.textContent === '...') typing.remove();

      if (res.ok) {
        const data = await res.json();
        appendChat('axi', `${data.text}\n[${data.provider}]`);
      } else {
        appendChat('axi', 'Error al contactar al LLM.');
      }
    } catch (err) {
      const typing = chatMessages.querySelector('.chat-msg-axi:last-child');
      if (typing && typing.textContent === '...') typing.remove();
      appendChat('axi', `Error: ${err.message}`);
    }
  });
}

function appendChat(role, text) {
  if (!chatMessages) return;
  const div = document.createElement('div');
  div.className = `chat-msg chat-msg-${role === 'user' ? 'user' : 'axi'}`;
  div.textContent = text;
  chatMessages.appendChild(div);
  chatMessages.scrollTop = chatMessages.scrollHeight;
}

// --- System Resources ---
let resourcesGridInitialized = false;
function ensureResourcesGrid() {
  if (resourcesGridInitialized) return;
  const grid = $('#resources-grid');
  if (!grid) return;
  grid.innerHTML = `
    <div class="resource-item"><span class="resource-label">CPU</span><div class="resource-bar"><div class="resource-fill" id="res-cpu-bar"></div></div><span class="resource-value" id="res-cpu">—</span></div>
    <div class="resource-item"><span class="resource-label">RAM</span><div class="resource-bar"><div class="resource-fill" id="res-ram-bar"></div></div><span class="resource-value" id="res-ram">—</span></div>
    <div class="resource-item"><span class="resource-label">Disco</span><div class="resource-bar"><div class="resource-fill" id="res-disk-bar"></div></div><span class="resource-value" id="res-disk">—</span></div>
    <div class="resource-item"><span class="resource-label">GPU</span><div class="resource-bar"><div class="resource-fill resource-fill-gpu" id="res-gpu-bar"></div></div><span class="resource-value" id="res-gpu">—</span></div>
  `;
  resourcesGridInitialized = true;
}

async function refreshResources() {
  try {
    const res = await fetch(`${API}/system/resources`, { headers: apiHeaders() });
    if (!res.ok) return;
    const d = await res.json();
    ensureResourcesGrid();

    const cpuPct = d.cpu_percent || 0;
    const ramPct = d.memory_percent || 0;
    const diskPct = d.disk_percent || 0;
    const ramUsed = d.memory_used_gb || 0;
    const ramTotal = d.memory_total_gb || 0;
    const diskUsed = d.disk_used_gb || 0;
    const diskTotal = d.disk_total_gb || 0;

    setBar('res-cpu-bar', 'res-cpu', cpuPct, `${cpuPct.toFixed(0)}%`);
    setBar('res-ram-bar', 'res-ram', ramPct,
      `${ramUsed.toFixed(1)} / ${ramTotal.toFixed(1)} GB (${ramPct.toFixed(0)}%)`);
    setBar('res-disk-bar', 'res-disk', diskPct,
      `${diskUsed.toFixed(0)} / ${diskTotal.toFixed(0)} GB (${diskPct.toFixed(0)}%)`);

    refreshGpu();
  } catch (e) { /* silent */ }
}

async function refreshGpu() {
  try {
    const res = await fetch(`${API}/system/info`, { headers: apiHeaders() });
    if (!res.ok) return;
    const d = await res.json();
    const gpuName = d.gpu_model || d.gpu_name || '';
    if (gpuName && gpuName !== 'N/A' && gpuName !== '') {
      const gpuUsed = d.gpu_vram_used_mb || 0;
      const gpuTotal = d.gpu_vram_total_mb || 0;
      if (gpuTotal > 0) {
        const gpuPct = (gpuUsed / gpuTotal) * 100;
        setBar('res-gpu-bar', 'res-gpu', gpuPct,
          `${(gpuUsed/1024).toFixed(1)} / ${(gpuTotal/1024).toFixed(1)} GB (${gpuPct.toFixed(0)}%)`);
      } else {
        const gpuEl = $('#res-gpu');
        if (gpuEl) gpuEl.textContent = gpuName;
      }
      // Also update AI Local section
      const aiGpu = $('#ai-gpu-name');
      if (aiGpu) aiGpu.textContent = gpuName;
    } else {
      const gpuEl = $('#res-gpu');
      if (gpuEl) gpuEl.textContent = 'CPU only';
    }
  } catch (e) { /* silent */ }
}

function setBar(barId, labelId, pct, label) {
  const bar = $(`#${barId}`);
  const lbl = $(`#${labelId}`);
  if (bar) bar.style.width = `${Math.min(pct, 100)}%`;
  if (lbl) lbl.textContent = label;
  // Color coding
  if (bar) {
    bar.style.background = pct > 90 ? 'var(--danger)' : pct > 70 ? 'var(--warning)' : 'var(--accent)';
  }
}

// --- LLM Providers ---
async function refreshProviders() {
  try {
    const res = await fetch(`${API}/llm/providers`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const grid = $('#providers-grid');
    if (!grid || !data.providers) return;

    grid.innerHTML = data.providers.map(p => {
      const n = p.name;
      const tier = n.startsWith('local') ? 'local' :
                   n.startsWith('cerebras') ? 'free' :
                   n.startsWith('groq') ? 'free' :
                   n.startsWith('zai') ? 'cheap' : 'free';
      const privacy = n.startsWith('local') ? 'Maxima' :
                      n.startsWith('cerebras') ? 'Alta (ZDR)' :
                      n.startsWith('groq') ? 'Alta (ZDR)' :
                      n.startsWith('anthropic') ? 'Media (no training)' :
                      n.startsWith('openai') ? 'Media (no training)' :
                      n.startsWith('gemini') ? 'Baja (free entrena)' :
                      n.startsWith('zai') || n.startsWith('kimi') || n.startsWith('minimax') ? 'Baja (China)' :
                      n.startsWith('openrouter') ? 'Variable' : '?';
      const privacyColor = privacy.startsWith('Max') ? 'var(--success)' :
                           privacy.startsWith('Alta') ? 'var(--accent-2)' :
                           privacy.startsWith('Media') ? 'var(--warning)' :
                           privacy.startsWith('Baja') ? 'var(--danger)' : 'var(--text-muted)';
      return `<div class="provider-card" data-tier="${tier}">
        <div class="provider-name">${escapeHtml(n)}</div>
        <div class="provider-stats">${p.total_requests} req | ${p.total_output_tokens} tok | ${p.total_failures} err</div>
        <div class="provider-stats" style="color:${privacyColor}">Privacidad: ${privacy}</div>
      </div>`;
    }).join('');

    // Update key status indicators
    updateKeyStatus('cerebras', data.providers.some(p => p.name.includes('cerebras') && p.total_requests > 0));
    updateKeyStatus('groq', data.providers.some(p => p.name.includes('groq') && p.total_requests > 0));
    updateKeyStatus('zai', data.providers.some(p => p.name.includes('zai') && p.total_requests > 0));
    updateKeyStatus('openrouter', data.providers.some(p => p.name.includes('openrouter') && p.total_requests > 0));
  } catch (e) { /* silent */ }
}

function updateKeyStatus(name, working) {
  const el = $(`#key-status-${name}`);
  if (el) el.textContent = working ? '\u2705' : '\u26A0\uFE0F';
}

// --- API Keys Status & Save ---
async function refreshKeyStatus() {
  try {
    const res = await fetch(`${API}/settings/keys`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const keys = data.keys || {};
    const map = {
      'CEREBRAS_API_KEY': 'cerebras',
      'GROQ_API_KEY': 'groq',
      'OPENROUTER_API_KEY': 'openrouter',
      'LIFEOS_TELEGRAM_BOT_TOKEN': 'telegram',
      'LIFEOS_TELEGRAM_CHAT_ID': 'telegram-chatid',
    };
    for (const [env, name] of Object.entries(map)) {
      const el = $(`#key-status-${name}`);
      if (el) el.textContent = keys[env] ? '\u2705' : '\u274C';
    }
  } catch (e) { /* silent */ }
}

const saveKeysBtn = $('#save-keys-btn');
if (saveKeysBtn) {
  saveKeysBtn.addEventListener('click', async () => {
    const keys = {};
    document.querySelectorAll('.provider-key-form input[data-env]').forEach(input => {
      const val = input.value.trim();
      if (val) keys[input.dataset.env] = val;
    });

    if (Object.keys(keys).length === 0) {
      $('#keys-hint').textContent = 'No hay keys para guardar. Escribe al menos una.';
      return;
    }

    saveKeysBtn.textContent = 'Guardando...';
    try {
      const res = await fetch(`${API}/settings/keys`, {
        method: 'POST', headers: apiHeaders(),
        body: JSON.stringify({ keys })
      });
      if (res.ok) {
        const data = await res.json();
        saveKeysBtn.textContent = 'Guardado!';
        saveKeysBtn.style.background = 'var(--success)';
        $('#keys-hint').textContent = `${data.updated} key(s) guardadas en ${data.path}. ${data.note}`;
        // Clear inputs after save
        document.querySelectorAll('.provider-key-form input[data-env]').forEach(i => { i.value = ''; });
        refreshKeyStatus();
      } else {
        saveKeysBtn.textContent = 'Error';
        saveKeysBtn.style.background = 'var(--danger)';
      }
    } catch (err) {
      saveKeysBtn.textContent = 'Error';
      saveKeysBtn.style.background = 'var(--danger)';
      $('#keys-hint').textContent = 'Error: ' + err.message;
    } finally {
      setTimeout(() => { saveKeysBtn.textContent = 'Guardar Keys'; saveKeysBtn.style.background = ''; }, 3000);
    }
  });
}

// --- Local Models ---
async function refreshModels() {
  try {
    const res = await fetch(`${API}/ai/models`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const grid = $('#models-grid');
    if (!grid) return;

    const status = await fetch(`${API}/ai/status`, { headers: apiHeaders() }).then(r => r.json()).catch(() => ({}));
    const activeModel = status.default_model || '';

    const models = data.models || [];
    if (models.length === 0) {
      grid.innerHTML = '<p class="task-empty">No hay modelos en /var/lib/lifeos/models/</p>';
      return;
    }

    grid.innerHTML = models.map(m => {
      const isActive = m.name === activeModel;
      return `<div class="model-card ${isActive ? 'active' : ''}">
        <div class="model-name">${escapeHtml(m.name)}</div>
        <div class="model-size">${m.size_mb} MB</div>
        ${isActive ? '<span class="model-badge">Activo</span>' : ''}
      </div>`;
    }).join('');
  } catch (e) { /* silent */ }
}

// --- Local AI Config ---
const aiCtxSlider = $('#ai-ctx-slider');
const aiCtxValue = $('#ai-ctx-value');
const aiGpuLayers = $('#ai-gpu-layers');
const aiGpuLayersValue = $('#ai-gpu-layers-value');
const aiThreads = $('#ai-threads');
const aiThreadsValue = $('#ai-threads-value');

if (aiCtxSlider) {
  aiCtxSlider.addEventListener('input', () => {
    if (aiCtxValue) aiCtxValue.textContent = aiCtxSlider.value;
  });
}
if (aiGpuLayers) {
  aiGpuLayers.addEventListener('input', () => {
    const v = aiGpuLayers.value;
    if (aiGpuLayersValue) aiGpuLayersValue.textContent = v === '99' ? '99 (todas)' : v;
  });
}
if (aiThreads) {
  aiThreads.addEventListener('input', () => {
    if (aiThreadsValue) aiThreadsValue.textContent = aiThreads.value;
  });
}

async function refreshAiStatus() {
  try {
    const res = await fetch(`${API}/ai/status`, { headers: apiHeaders() });
    if (!res.ok) return;
    const d = await res.json();
    const activeModel = $('#ai-active-model');
    const serverStatus = $('#ai-server-status');
    const gpuName = $('#ai-gpu-name');
    if (activeModel) activeModel.textContent = d.default_model || '—';
    if (serverStatus) serverStatus.textContent = d.server_running ? 'Corriendo' : 'Detenido';
    if (gpuName) gpuName.textContent = d.gpu_acceleration ? 'Activa' : 'CPU only';

    // Mark installed models in catalog
    const models = d.models || [];
    document.querySelectorAll('.catalog-item').forEach(item => {
      const modelName = item.dataset.model + '.gguf';
      if (models.some(m => m.name === modelName)) {
        item.classList.add('installed');
      }
    });
  } catch (e) { /* silent */ }
}

// Catalog click to select model
document.querySelectorAll('.catalog-item').forEach(item => {
  item.addEventListener('click', () => {
    const model = item.dataset.model;
    if (item.classList.contains('installed')) {
      item.querySelector('.catalog-desc').textContent = 'Ya instalado. Seleccionar como activo requiere reiniciar llama-server.';
    } else {
      item.querySelector('.catalog-desc').textContent = 'Descarga no disponible desde el dashboard aun. Usa: life ai pull ' + model;
    }
  });
});

// --- Agent Metrics ---
async function refreshMetrics() {
  try {
    const res = await fetch(`${API}/supervisor/metrics`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();

    const total = data.total_tasks || 0;
    const completed = data.total_completed || 0;
    const failed = data.total_failed || 0;
    const rate = total > 0 ? ((completed / total) * 100).toFixed(0) + '%' : '—';

    const metTotal = $('#met-total');
    const metCompleted = $('#met-completed');
    const metFailed = $('#met-failed');
    const metRate = $('#met-rate');
    if (metTotal) metTotal.textContent = total;
    if (metCompleted) metCompleted.textContent = completed;
    if (metFailed) metFailed.textContent = failed;
    if (metRate) metRate.textContent = rate;

    const rolesDiv = $('#metrics-roles');
    if (rolesDiv && data.by_role) {
      rolesDiv.innerHTML = Object.entries(data.by_role).map(([role, m]) => {
        return `<div class="metric-role-card">
          <div class="metric-role-name">${escapeHtml(role)}</div>
          <div class="metric-role-stats">${m.tasks_completed} OK | ${m.tasks_failed} fail | avg ${m.avg_duration_ms}ms</div>
        </div>`;
      }).join('');
    }
  } catch (e) { /* silent */ }
}

// --- Memory Plane ---
async function refreshMemory() {
  try {
    const res = await fetch(`${API}/memory/stats`, { headers: apiHeaders() });
    if (!res.ok) return;
    const d = await res.json();
    const memTotal = $('#mem-total');
    const memDecisions = $('#mem-decisions');
    const memEvents = $('#mem-events');
    const memNotes = $('#mem-notes');
    if (memTotal) memTotal.textContent = d.total_entries || 0;
    if (memDecisions) memDecisions.textContent = d.by_kind?.decision || 0;
    if (memEvents) memEvents.textContent = d.by_kind?.event || 0;
    if (memNotes) memNotes.textContent = d.by_kind?.note || 0;
  } catch (e) { /* silent */ }
}

async function searchMemory(query) {
  try {
    const res = await fetch(`${API}/memory/search`, {
      method: 'POST', headers: apiHeaders(),
      body: JSON.stringify({ query, limit: 10 })
    });
    if (!res.ok) return;
    const data = await res.json();
    const container = $('#memory-entries');
    if (!container) return;

    const entries = data.entries || data.results || [];
    if (entries.length === 0) {
      container.innerHTML = '<p class="task-empty">Sin resultados</p>';
      return;
    }

    container.innerHTML = entries.map(e => {
      const entry = e.entry || e;
      return `<div class="memory-entry">
        <div class="memory-entry-kind">${escapeHtml(entry.kind || '?')}</div>
        <div class="memory-entry-content">${escapeHtml((entry.content || '').substring(0, 400))}</div>
        <div class="memory-entry-meta">${entry.created_at || ''} | importancia: ${entry.importance || 0} | tags: ${(entry.tags || []).join(', ')}</div>
      </div>`;
    }).join('');
  } catch (e) {
    const container = $('#memory-entries');
    if (container) container.innerHTML = '<p class="task-empty">Error al buscar</p>';
  }
}

const memSearchBtn = $('#memory-search-btn');
const memSearchInput = $('#memory-search-input');
if (memSearchBtn) {
  memSearchBtn.addEventListener('click', () => {
    const q = memSearchInput?.value?.trim();
    if (q) searchMemory(q);
  });
}
if (memSearchInput) {
  memSearchInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const q = memSearchInput.value.trim();
      if (q) searchMemory(q);
    }
  });
}

// --- Scheduled Tasks ---
async function refreshScheduledTasks() {
  try {
    const res = await fetch(`${API}/tasks/scheduled`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const list = $('#sched-list');
    if (!list) return;

    if (!data.tasks || data.tasks.length === 0) {
      list.innerHTML = '<p class="task-empty">Sin tareas programadas</p>';
      return;
    }

    list.innerHTML = data.tasks.map(t => `
      <div class="sched-item">
        <div class="sched-item-info">
          <strong>${escapeHtml(t.objective)}</strong>
          <div class="sched-item-schedule">${t.schedule_type === 'interval' ? 'Cada N min' : 'Diario'}: ${escapeHtml(t.schedule_param)}</div>
        </div>
        <button class="icon-btn" style="color:var(--danger); width:28px; height:28px; font-size:1rem; display:flex; align-items:center; justify-content:center;" onclick="deleteScheduledTask('${t.id}')" title="Eliminar">&times;</button>
      </div>
    `).join('');
  } catch (e) { /* silent */ }
}

window.deleteScheduledTask = async (id) => {
  try {
    await api('DELETE', `/tasks/scheduled/${id}`);
    await refreshScheduledTasks();
  } catch (err) { addFeedItem('&#10060;', 'Error al eliminar tarea programada'); }
};

const schedAddBtn = $('#sched-add-btn');
if (schedAddBtn) {
  schedAddBtn.addEventListener('click', async () => {
    const objective = $('#sched-objective').value.trim();
    const type = $('#sched-type').value;
    const param = $('#sched-param').value.trim();
    if (!objective || !param) return;

    schedAddBtn.textContent = '...';
    try {
      await api('POST', '/tasks/scheduled', { objective, schedule_type: type, schedule_param: param });
      $('#sched-objective').value = '';
      $('#sched-param').value = '';
      await refreshScheduledTasks();
    } catch (err) {
      addFeedItem('&#10060;', `Error al programar: ${err.message}`);
    } finally {
      schedAddBtn.textContent = 'Programar';
    }
  });
}

// --- OS Actions ---
window.setOsMode = async (mode) => {
  try {
    addFeedItem('&#9881;', `Cambiando a modo: ${mode}...`);
    // Simulando llamada a la API (o a implementar en el backend Rust: POST /system/mode)
    await api('POST', '/system/mode', { mode });
    addFeedItem('&#9989;', `Modo ${mode} activado`);
  } catch (err) {
    addFeedItem('&#10060;', `Error al cambiar modo: ${err.message}`);
  }
};

window.triggerSystemAction = async (action) => {
  const confirmMsg = action === 'rollback' ? '¿Seguro que deseas volver a la imagen anterior del sistema (Rollback)?' : 
                     action === 'recover' ? '¿Ejecutar diagnostico y auto-reparacion del OS?' : null;
                     
  if (confirmMsg && !confirm(confirmMsg)) return;
  
  try {
    addFeedItem('&#9881;', `Iniciando accion: ${action}...`);
    // Llamar endpoints que orquesten comandos CLI equivalentes
    await api('POST', `/system/actions/${action}`, {});
    addFeedItem('&#9989;', `Accion ${action} completada`);
  } catch (err) {
    addFeedItem('&#10060;', `Error en accion ${action}: ${err.message}`);
  }
};

// --- Polling ---
setInterval(() => {
  refreshSupervisor();
  refreshTasks();
  refreshResources();
  refreshMetrics();
  refreshScheduledTasks();
  refreshSystemHealth();
}, 10000);

// Less frequent polls
setInterval(() => {
  refreshProviders();
  refreshModels();
  refreshMemory();
  refreshAiStatus();
  refreshKeyStatus();
  refreshGameGuard();
}, 30000);

// --- System Health ---
function healthDot(id, value, greenBelow, yellowBelow, invert) {
  // invert: true means lower is worse (e.g., SSD health %, battery health %)
  // default: higher is worse (e.g., temp, disk usage)
  const dot = $(`#${id}`);
  if (!dot) return;
  let color;
  if (value == null || isNaN(value)) {
    color = 'var(--text-muted)';
  } else if (invert) {
    // Higher is better: green > greenBelow, yellow > yellowBelow, red otherwise
    color = value > greenBelow ? 'var(--success)' : value > yellowBelow ? 'var(--warning)' : 'var(--danger)';
  } else {
    // Higher is worse: green < greenBelow, yellow < yellowBelow, red otherwise
    color = value < greenBelow ? 'var(--success)' : value < yellowBelow ? 'var(--warning)' : 'var(--danger)';
  }
  dot.style.background = color;
  dot.style.boxShadow = `0 0 6px ${color}`;
}

let lastBatteryData = null;

async function refreshSystemHealth() {
  try {
    // Fetch system resources for CPU/RAM/disk
    const resRes = await fetch(`${API}/system/resources`, { headers: apiHeaders() });
    if (resRes.ok) {
      const d = await resRes.json();
      const ramPct = d.memory_percent || 0;
      const diskPct = d.disk_percent || 0;
      const cpuTemp = d.cpu_temp_c;
      const gpuTemp = d.gpu_temp_c;
      const ssdHealth = d.ssd_health_percent;

      // CPU temp
      if (cpuTemp != null && !isNaN(cpuTemp)) {
        $('#health-cpu-temp').textContent = `${cpuTemp.toFixed(0)}°C`;
        healthDot('health-dot-cpu-temp', cpuTemp, 70, 85, false);
      } else {
        $('#health-cpu-temp').textContent = 'N/A';
        healthDot('health-dot-cpu-temp', null);
      }

      // GPU temp
      if (gpuTemp != null && !isNaN(gpuTemp)) {
        $('#health-gpu-temp').textContent = `${gpuTemp.toFixed(0)}°C`;
        healthDot('health-dot-gpu-temp', gpuTemp, 70, 85, false);
      } else {
        $('#health-gpu-temp').textContent = 'N/A';
        healthDot('health-dot-gpu-temp', null);
      }

      // SSD health
      if (ssdHealth != null && !isNaN(ssdHealth)) {
        $('#health-ssd').textContent = `${ssdHealth.toFixed(0)}%`;
        healthDot('health-dot-ssd', ssdHealth, 80, 60, true);
      } else {
        $('#health-ssd').textContent = 'N/A';
        healthDot('health-dot-ssd', null);
      }

      // Disk usage
      $('#health-disk').textContent = `${diskPct.toFixed(0)}%`;
      healthDot('health-dot-disk', diskPct, 80, 90, false);

      // RAM usage
      $('#health-ram').textContent = `${ramPct.toFixed(0)}%`;
      healthDot('health-dot-ram', ramPct, 80, 90, false);
    }
  } catch (e) { /* silent */ }

  // Fetch battery status
  try {
    const batRes = await fetch(`${API}/battery/status`, { headers: apiHeaders() });
    if (batRes.ok) {
      const b = await batRes.json();
      lastBatteryData = b;
      const batSection = $('#battery-section');

      if (b.present) {
        // Show battery section
        if (batSection) batSection.classList.remove('hidden');

        // Battery health dot in system health
        const batHealthPct = b.health_percent;
        if (batHealthPct != null && !isNaN(batHealthPct)) {
          $('#health-battery').textContent = `${batHealthPct.toFixed(0)}%`;
          healthDot('health-dot-battery', batHealthPct, 80, 70, true);
        } else {
          $('#health-battery').textContent = 'N/A';
          healthDot('health-dot-battery', null);
        }

        // Battery section details
        const chargeEl = $('#bat-charge');
        const healthEl = $('#bat-health');
        const cyclesEl = $('#bat-cycles');
        const profileEl = $('#bat-profile');
        const vendorEl = $('#bat-vendor');
        const thresholdSlider = $('#bat-threshold-slider');
        const thresholdValue = $('#bat-threshold-value');

        if (chargeEl) chargeEl.textContent = b.charge_percent != null ? `${b.charge_percent.toFixed(0)}%` : '—';
        if (healthEl) healthEl.textContent = batHealthPct != null ? `${batHealthPct.toFixed(0)}%` : '—';
        if (cyclesEl) cyclesEl.textContent = b.cycle_count != null ? `${b.cycle_count}` : '—';
        if (profileEl) profileEl.textContent = b.power_profile || '—';
        if (vendorEl) vendorEl.textContent = b.vendor || '—';
        if (thresholdSlider && b.charge_threshold != null && !thresholdSlider._userTouched) {
          thresholdSlider.value = b.charge_threshold;
          if (thresholdValue) thresholdValue.textContent = `${b.charge_threshold}%`;
        }
      } else {
        // No battery — hide section, show N/A in health
        if (batSection) batSection.classList.add('hidden');
        $('#health-battery').textContent = 'N/A';
        healthDot('health-dot-battery', null);
      }
    }
  } catch (e) {
    // Battery endpoint not available — hide battery section
    const batSection = $('#battery-section');
    if (batSection) batSection.classList.add('hidden');
    $('#health-battery').textContent = 'N/A';
    healthDot('health-dot-battery', null);
  }

  // Service status
  try {
    // Daemon is always running if we got here
    setServiceStatus('svc-daemon', 'svc-dot-daemon', 'Activo', 'ok');

    // LLM server
    const aiRes = await fetch(`${API}/ai/status`, { headers: apiHeaders() }).catch(() => null);
    if (aiRes && aiRes.ok) {
      const ai = await aiRes.json();
      setServiceStatus('svc-llm', 'svc-dot-llm',
        ai.server_running ? 'Activo' : 'Detenido',
        ai.server_running ? 'ok' : 'warn');
    } else {
      setServiceStatus('svc-llm', 'svc-dot-llm', 'Sin respuesta', 'error');
    }

    // STT (whisper)
    const sensoryRes = await fetch(`${API}/sensory/status`, { headers: apiHeaders() }).catch(() => null);
    if (sensoryRes && sensoryRes.ok) {
      const s = await sensoryRes.json();
      const sttOk = s.capabilities && s.capabilities.whisper_binary;
      setServiceStatus('svc-stt', 'svc-dot-stt',
        sttOk ? 'Disponible' : 'No encontrado',
        sttOk ? 'ok' : 'warn');
    } else {
      setServiceStatus('svc-stt', 'svc-dot-stt', '—', 'neutral');
    }

    // Telegram
    const tgToken = !!document.querySelector('#key-status-telegram.ok');
    setServiceStatus('svc-telegram', 'svc-dot-telegram',
      tgToken ? 'Configurado' : 'Sin configurar',
      tgToken ? 'ok' : 'neutral');
  } catch (e) { /* silent */ }
}

function setServiceStatus(valId, dotId, text, level) {
  const val = $(`#${valId}`);
  const dot = $(`#${dotId}`);
  if (val) val.textContent = text;
  if (dot) {
    dot.style.background = level === 'ok' ? 'var(--success)' :
                           level === 'warn' ? '#f39c12' :
                           level === 'error' ? 'var(--danger)' : '#555';
  }
}

// Battery threshold slider
const batThresholdSlider = document.getElementById('bat-threshold-slider');
const batThresholdValue = document.getElementById('bat-threshold-value');
if (batThresholdSlider) {
  batThresholdSlider.addEventListener('input', () => {
    batThresholdSlider._userTouched = true;
    if (batThresholdValue) batThresholdValue.textContent = `${batThresholdSlider.value}%`;
  });
}

const batThresholdSave = document.getElementById('bat-threshold-save');
if (batThresholdSave) {
  batThresholdSave.addEventListener('click', async () => {
    const val = parseInt(batThresholdSlider?.value || '80', 10);
    try {
      await fetch(`${API}/battery/threshold`, {
        method: 'POST',
        headers: apiHeaders(),
        body: JSON.stringify({ threshold: val })
      });
      batThresholdSave.textContent = 'Aplicado';
      setTimeout(() => { batThresholdSave.textContent = 'Aplicar umbral'; }, 2000);
      if (batThresholdSlider) batThresholdSlider._userTouched = false;
    } catch (e) {
      batThresholdSave.textContent = 'Error';
      setTimeout(() => { batThresholdSave.textContent = 'Aplicar umbral'; }, 2000);
    }
  });
}

// --- Game Guard ---
async function refreshGameGuard() {
  try {
    const res = await fetch(`${API}/game-guard/status`, { headers: apiHeaders() });
    if (!res.ok) return;
    const d = await res.json();
    const modeEl = $('#gg-llm-mode');
    const gameEl = $('#gg-game-name');
    const guardToggle = $('#toggle-game-guard');
    const assistToggle = $('#toggle-game-assistant');
    const guardStatus = $('#gg-guard-status');
    const assistStatus = $('#gg-assistant-status');

    if (modeEl) {
      modeEl.textContent = d.llm_mode === 'cpu' ? 'CPU (RAM)' : 'GPU (VRAM)';
      modeEl.style.color = d.llm_mode === 'cpu' ? 'var(--warning)' : 'var(--success)';
    }
    if (gameEl) gameEl.textContent = d.game_name || 'Ninguno';
    const detailEl = $('#gg-game-detail');
    if (detailEl) {
      if (d.game_detected && d.game_name) {
        const title = d.game_window_title ? ` — ${d.game_window_title}` : '';
        detailEl.textContent = `Juego activo: ${d.game_name} (PID ${d.game_pid})${title}. LLM movido a RAM.`;
      } else {
        detailEl.textContent = '';
      }
    }
    if (guardToggle) guardToggle.checked = d.guard_enabled;
    if (assistToggle) assistToggle.checked = d.assistant_enabled;
    if (guardStatus) guardStatus.textContent = d.guard_enabled ? 'Activo' : 'Desactivado';
    if (assistStatus) assistStatus.textContent = d.assistant_enabled ? 'Activo' : 'Desactivado';
  } catch (e) { /* silent */ }
}

// Game Guard toggles
document.getElementById('toggle-game-guard')?.addEventListener('change', async (e) => {
  try {
    await fetch(`${API}/game-guard/toggle`, {
      method: 'POST', headers: apiHeaders(),
      body: JSON.stringify({ enabled: e.target.checked })
    });
  } catch (err) { /* silent */ }
});

document.getElementById('toggle-game-assistant')?.addEventListener('change', async (e) => {
  try {
    await fetch(`${API}/game-guard/assistant-toggle`, {
      method: 'POST', headers: apiHeaders(),
      body: JSON.stringify({ enabled: e.target.checked })
    });
  } catch (err) { /* silent */ }
});

// --- Tabs Initialization ---
function initTabs() {
  const main = document.querySelector('main');
  if (!main) return;

  const nav = document.createElement('nav');
  nav.className = 'dashboard-tabs';

  const tabs = [
    { id: 'tab-home', icon: '&#127968;', label: 'Inicio', keywords: ['hero-panel', 'orb-section', 'controls-section', 'status-section', 'chat-section'] },
    { id: 'tab-agents', icon: '&#9881;', label: 'Operaciones', keywords: ['supervisor-section', 'metrics-section', 'sched-section', 'feed-section'] },
    { id: 'tab-memory', icon: '&#128450;', label: 'Memoria', keywords: ['memory-section'] },
    { id: 'tab-system', icon: '&#128187;', label: 'Sistema & IA', keywords: ['os-config-section', 'resources-section', 'health-section', 'battery-section', 'localai-section', 'models-section', 'gameguard-section', 'providers-section', 'settings-section'] }
  ];

  const tabContents = document.createElement('div');
  tabContents.className = 'tab-contents';

  const children = Array.from(main.children);

  tabs.forEach((tab, index) => {
    const btn = document.createElement('button');
    btn.className = 'tab-btn' + (index === 0 ? ' active' : '');
    btn.innerHTML = `<span style="margin-right:4px">${tab.icon}</span> ${tab.label}`;
    btn.dataset.target = tab.id;

    const content = document.createElement('div');
    content.id = tab.id;
    content.className = 'tab-pane' + (index === 0 ? ' active' : '');

    children.forEach(child => {
      if (tab.keywords.some(kw => (child.className && child.className.includes(kw)) || (child.id && child.id.includes(kw)))) {
        content.appendChild(child);
      }
    });

    btn.addEventListener('click', () => {
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
      btn.classList.add('active');
      content.classList.add('active');
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });

    nav.appendChild(btn);
    tabContents.appendChild(content);
  });

  main.insertBefore(nav, main.firstChild);
  main.appendChild(tabContents);
}

// --- Boot ---
(async () => {
  initTabs();
  await ensureBootstrapToken();
  await fetchInitialState();
  connectSSE();
  refreshSupervisor();
  refreshTasks();
  refreshResources();
  refreshProviders();
  refreshModels();
  refreshMetrics();
  refreshMemory();
  refreshScheduledTasks();
  refreshAiStatus();
  refreshKeyStatus();
  refreshGameGuard();
  refreshSystemHealth();
  runWelcomeSequence().catch(err => console.warn('welcome sequence failed:', err));
})();
