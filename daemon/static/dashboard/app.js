// LifeOS Dashboard — API client, SSE listener, diagnostics, UI logic
'use strict';

// --- Single-instance guard ---
// Prevents multiple dashboard tabs. If one is already open, the new tab
// transfers its token (if any) and closes itself.
(function singleInstanceGuard() {
  const ch = new BroadcastChannel('lifeos-dashboard');
  const params = new URLSearchParams(location.search);
  const newToken = params.get('token') || '';

  // Ask if another tab is already open
  let answered = false;
  ch.postMessage({ type: 'ping', token: newToken });

  ch.onmessage = (e) => {
    if (e.data.type === 'ping') {
      // Another tab is trying to open — send it a pong so it closes
      // Accept its token if it has one (fresher than ours)
      if (e.data.token) {
        sessionStorage.setItem('lifeos_token', e.data.token);
        token = e.data.token;
      }
      ch.postMessage({ type: 'pong' });
      // Flash the tab title to signal we're here
      const orig = document.title;
      document.title = '▶ LifeOS Dashboard';
      setTimeout(() => { document.title = orig; }, 2000);
      window.focus();
    } else if (e.data.type === 'pong' && !answered) {
      // Another tab answered — we're the duplicate, close ourselves
      answered = true;
      window.close();
      // window.close() only works for JS-opened windows; if it fails,
      // redirect to a helpful message instead of showing a second dashboard
      setTimeout(() => {
        document.body.innerHTML = '<div style="display:flex;align-items:center;justify-content:center;height:100vh;color:#aaa;font-family:Inter,sans-serif;flex-direction:column;gap:12px"><h2>Dashboard ya abierto en otra pestaña</h2><p>Podés cerrar esta pestaña.</p></div>';
      }, 300);
    }
  };
})();

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
  if (dashboardState.alwaysOn?.enabled) activeSensors.push('always-on');
  if (runtime.tts_enabled) activeSensors.push('habla');
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

  const activeSensors = [
    runtime.audio_enabled,
    dashboardState.alwaysOn?.enabled,
    runtime.tts_enabled,
    runtime.screen_enabled,
    runtime.camera_enabled,
  ].filter(Boolean).length;
  const sensorText = activeSensors
    ? `${activeSensors} activo${activeSensors === 1 ? '' : 's'}`
    : 'Sin sensores activos';
  const sensorState = activeSensors ? (activeSensors === 5 ? 'chip-ok' : 'chip-warn') : 'chip-error';
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
  $('#toggle-tts').checked = runtime.tts_enabled;
  $('#toggle-screen').checked = runtime.screen_enabled;
  $('#toggle-camera').checked = runtime.camera_enabled;
  const toggleMeeting = $('#toggle-meeting-capture');
  if (toggleMeeting) {
    toggleMeeting.checked = runtime.meeting_enabled !== false;
  }
  $('#audio-status').textContent = runtime.audio_enabled ? 'Activo' : 'Inactivo';
  $('#tts-status').textContent = runtime.tts_enabled ? 'Activo' : 'Inactivo';
  $('#screen-status').textContent = runtime.screen_enabled ? 'Activo' : 'Inactivo';
  $('#camera-status').textContent = runtime.camera_enabled ? 'Activo' : 'Inactivo';
  const meetingCaptureStatus = $('#meeting-capture-status');
  if (meetingCaptureStatus) {
    meetingCaptureStatus.textContent =
      runtime.meeting_enabled !== false ? 'Activo' : 'Inactivo';
  }
  updateKillSwitchUi(runtime.kill_switch_active);
  renderHero();
}

function updateAlwaysOn(ao) {
  dashboardState.alwaysOn = ao;
  $('#toggle-always-on').checked = ao.enabled;
  $('#always-on-status').textContent = ao.enabled ? 'Activo' : 'Inactivo';
  if (ao.wake_word) $('#wake-word-input').value = ao.wake_word;
  renderHero();
}

function updateKillSwitchUi(active) {
  const btn = $('#kill-switch');
  if (!btn) return;
  btn.dataset.active = active ? 'true' : 'false';
  btn.textContent = active ? 'REACTIVAR SENTIDOS' : 'KILL SWITCH';
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

// --- WebSocket connection ---
const wsBadge = $('#ws-badge');
let ws = null;
let wsReconnectTimer = null;
let wsReconnectDelay = 1000;

function connectWebSocket() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${proto}//${location.host}/ws`;
  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    wsReconnectDelay = 1000;
    if (wsBadge) { wsBadge.textContent = 'WS'; wsBadge.className = 'badge badge-ws badge-online'; }
    addFeedItem('&#128279;', 'WebSocket conectado');

    // Subscribe to all events and send auth
    const subMsg = { type: 'subscribe', events: ['*'] };
    if (token) subMsg.token = token;
    ws.send(JSON.stringify(subMsg));
  };

  ws.onmessage = (e) => {
    if (!e.data) return;
    let msg;
    try { msg = JSON.parse(e.data); } catch { return; }

    // Handle server messages
    if (msg.type === 'event' && msg.data) {
      handleEvent(msg.data);
    } else if (msg.type === 'state_sync') {
      // Full state sync from WS
      if (msg.data?.axi_state) updateOrb(msg.data.axi_state, null, msg.data.reason || '');
    } else if (msg.type) {
      // Treat as direct event
      handleEvent(msg);
    }
  };

  ws.onclose = () => {
    if (wsBadge) { wsBadge.textContent = 'WS'; wsBadge.className = 'badge badge-ws badge-offline'; }
    scheduleWsReconnect();
  };

  ws.onerror = () => {
    if (wsBadge) { wsBadge.textContent = 'WS'; wsBadge.className = 'badge badge-ws badge-offline'; }
  };
}

function scheduleWsReconnect() {
  if (wsReconnectTimer) return;
  wsReconnectTimer = setTimeout(() => {
    wsReconnectTimer = null;
    wsReconnectDelay = Math.min(wsReconnectDelay * 1.5, 30000);
    connectWebSocket();
  }, wsReconnectDelay);
}

// --- SSE connection (fallback / primary for event stream) ---
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
      const wasKillSwitchActive = !!dashboardState.runtime?.kill_switch_active;
      dashboardState.runtime = {
        ...(dashboardState.runtime || {}),
        audio_enabled: event.data.mic,
        screen_enabled: event.data.screen,
        camera_enabled: event.data.camera,
        ...(event.data.tts != null ? { tts_enabled: event.data.tts } : {}),
        kill_switch_active: !!event.data.kill_switch,
      };
      if (event.data.always_on != null) {
        dashboardState.alwaysOn = {
          ...(dashboardState.alwaysOn || {}),
          enabled: !!event.data.always_on,
        };
        $('#toggle-always-on').checked = !!event.data.always_on;
        $('#always-on-status').textContent = event.data.always_on ? 'Activo' : 'Inactivo';
      }
      $('#toggle-audio').checked = event.data.mic;
      if (event.data.tts != null) $('#toggle-tts').checked = event.data.tts;
      $('#toggle-screen').checked = event.data.screen;
      $('#toggle-camera').checked = event.data.camera;
      $('#audio-status').textContent = event.data.mic ? 'Activo' : 'Inactivo';
      if (event.data.tts != null) $('#tts-status').textContent = event.data.tts ? 'Activo' : 'Inactivo';
      $('#screen-status').textContent = event.data.screen ? 'Activo' : 'Inactivo';
      $('#camera-status').textContent = event.data.camera ? 'Activo' : 'Inactivo';
      updateKillSwitchUi(event.data.kill_switch);
      renderHero();
      if (event.data.kill_switch) addFeedItem('&#9888;', 'Kill switch activado');
      else if (wasKillSwitchActive) addFeedItem('&#9989;', 'Kill switch liberado');
      break;
    case 'privacy_mode_changed':
      // Sync the toggle UI when the change originated from another surface
      // (tray menu, CLI). source is unknown here so we omit it and let the
      // tooltip stay as-is.
      renderPrivacyMode(Boolean(event.data?.enabled));
      addFeedItem('&#128274;', `Modo Privacidad ${event.data?.enabled ? 'activado' : 'desactivado'}`);
      break;
    case 'llm_config_changed':
      // Origin can be the dashboard itself, the CLI, or the API. Re-pull
      // the resolved status so the badge + slider reflect server truth
      // (we don't trust the event payload to know about runtime profile
      // fallback, only the resolver does).
      refreshLlmCtxSize();
      addFeedItem('&#9881;', `LLM ctx-size = ${event.data?.ctx_size ?? '?'} (${event.data?.source || 'desconocido'})`);
      break;
    case 'feedback_update':
      dashboardState.lastSignal = `Feedback ${event.data.stage || 'actualizado'}`;
      dashboardState.lastSignalAt = new Date().toISOString();
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
    case 'safe_mode_entered':
      if (safeBanner) safeBanner.classList.add('visible');
      addFeedItem('&#9888;', 'Axi entro en modo seguro');
      break;
    case 'safe_mode_exited':
      if (safeBanner) safeBanner.classList.remove('visible');
      addFeedItem('&#9989;', 'Axi salio de modo seguro');
      break;
    case 'health_check':
      addFeedItem('&#128154;', `Diagnostico: ${event.data.status || 'completado'}`);
      refreshDoctor();
      break;
    case 'task_completed':
    case 'task_failed':
      refreshTasks();
      refreshSupervisor();
      addFeedItem(event.type === 'task_completed' ? '&#9989;' : '&#10060;',
        `Tarea ${event.type === 'task_completed' ? 'completada' : 'fallida'}: ${event.data.objective || ''}`);
      break;
    case 'telegram_message':
      addFeedItem('&#128172;', `Telegram: ${(event.data.text || '').substring(0, 80)}`);
      break;
    case 'worker.started':
    case 'worker_started':
      addWorkerCard(event.data);
      addFeedItem('&#9881;', `Worker iniciado: ${(event.data.task || event.data.objective || '').substring(0, 60)}`);
      break;
    case 'worker.progress':
    case 'worker_progress':
      updateWorkerProgress(event.data);
      break;
    case 'worker.completed':
    case 'worker_completed':
      markWorkerCompleted(event.data);
      addFeedItem('&#9989;', `Worker completado: ${(event.data.task || event.data.objective || '').substring(0, 60)}`);
      break;
    case 'worker.failed':
    case 'worker_failed':
      markWorkerFailed(event.data);
      addFeedItem('&#10060;', `Worker fallido: ${(event.data.task || event.data.objective || '').substring(0, 60)}`);
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
  setVal('d-audio-tts', cap.tts_server_url ? cap.tts_server_url : 'No configurado', cap.tts_server_url ? '' : 'val-warn');
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

function populateTtsDiag(sensory) {
  const cap = sensory?.capabilities || {};
  const voice = sensory?.voice || {};
  const runtime = dashboardState.runtime || {};

  const ttsReady = !!cap.tts_server_url;
  const enabled = runtime.tts_enabled !== false;
  if (enabled && ttsReady) setDot('dot-tts', 'ok');
  else if (ttsReady) setDot('dot-tts', 'warn');
  else setDot('dot-tts', 'error');

  setVal('d-tts-binary', cap.tts_server_url || 'No configurado', cap.tts_server_url ? '' : 'val-error');
  const voices = cap.kokoro_voices;
  const voicesStr = Array.isArray(voices) && voices.length ? voices.map(v => v.name).join(', ') : 'Sin voces';
  setVal('d-tts-model', voicesStr, Array.isArray(voices) && voices.length ? 'val-ok' : 'val-warn');
  setVal('d-tts-engine', voice.last_tts_engine || '—');
  setVal('d-tts-backend', voice.last_playback_backend || '—');
  setVal('d-tts-enabled', enabled ? 'Activo' : 'Inactivo', enabled ? 'val-ok' : 'val-warn');
  setVal('d-tts-last', voice.last_response ? voice.last_response.substring(0, 200) : '(sin datos)');
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
    case 'tts': populateTtsDiag(sensory); break;
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
    case 'tts':
      return await api('POST', '/sensory/tts/speak', {
        text: 'Hola, soy Axi. Esta es una prueba de voz local.',
        playback: true,
      });
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
      if (sensor === 'tts') {
        const degraded = result.tts?.degraded_modes || [];
        if (degraded.includes('tts_disabled')) throw new Error('Habla esta desactivada');
        if (degraded.includes('tts_unavailable')) throw new Error('TTS local no disponible');
      }
      btn.textContent = 'OK';
      btn.classList.add('test-ok');
      if (resultEl) {
        if (result.snapshot?.transcript) resultEl.textContent = 'Texto: ' + result.snapshot.transcript;
        else if (result.snapshot?.screen_path) resultEl.textContent = 'Captura: ' + result.snapshot.screen_path;
        else if (result.tts) resultEl.textContent = result.tts.playback_started ? 'Voz reproducida correctamente' : 'TTS disponible pero sin reproduccion';
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
        const labels = {
          audio: '\u25B6 Probar Oido',
          tts: '\uD83D\uDD08 Probar Habla',
          screen: '\uD83D\uDCF7 Capturar Pantalla',
          camera: '\uD83D\uDCF7 Capturar Camara',
        };
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
      tts_enabled: current.tts_enabled,
      screen_enabled: current.screen_enabled,
      camera_enabled: current.camera_enabled,
      meeting_enabled: current.meeting_enabled !== false,
    };
    body[field] = value;
    // If enabling any sensor that needs the master on, ensure `enabled=true`.
    // `meeting_enabled` and `tts_enabled` are per-sense layers that don't
    // by themselves require the master toggle.
    const enableMasterOnTurnOn =
      field !== 'capture_interval_seconds'
      && field !== 'tts_enabled'
      && field !== 'meeting_enabled';
    if (value && enableMasterOnTurnOn) body.enabled = true;
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
$('#toggle-tts').addEventListener('change', (e) => toggleSensory('tts_enabled', e.target.checked, 'toggle-tts'));
$('#toggle-screen').addEventListener('change', (e) => toggleSensory('screen_enabled', e.target.checked, 'toggle-screen'));
$('#toggle-camera').addEventListener('change', (e) => toggleSensory('camera_enabled', e.target.checked, 'toggle-camera'));
{
  const meetingEl = $('#toggle-meeting-capture');
  if (meetingEl) {
    meetingEl.addEventListener('change', (e) =>
      toggleSensory(
        'meeting_enabled',
        e.target.checked,
        'toggle-meeting-capture',
      ),
    );
  }
}

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
  const killActive = $('#kill-switch')?.dataset.active === 'true';
  if (!confirm(killActive ? 'Reactivar los sentidos con el estado anterior?' : 'Desactivar TODOS los sentidos?')) return;
  await api('POST', '/sensory/kill-switch', { actor: 'dashboard' });
  addFeedItem('&#9888;', killActive ? 'Kill switch liberado desde el dashboard' : 'KILL SWITCH activado desde el dashboard');
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
function updateThemeIcon() {
  const isDark = document.documentElement.dataset.theme !== 'light';
  const moon = document.getElementById('theme-icon-moon');
  const sun = document.getElementById('theme-icon-sun');
  if (moon) moon.style.display = isDark ? 'block' : 'none';
  if (sun) sun.style.display = isDark ? 'none' : 'block';
}
$('#theme-toggle').addEventListener('click', () => {
  const html = document.documentElement;
  const next = html.dataset.theme === 'dark' ? 'light' : 'dark';
  html.dataset.theme = next;
  localStorage.setItem('lifeos-theme', next);
  updateThemeIcon();
});
const savedTheme = localStorage.getItem('lifeos-theme');
if (savedTheme) document.documentElement.dataset.theme = savedTheme;
updateThemeIcon();

// --- Clean token from URL (security: don't leave it in browser history) ---
if (params.get('token')) {
  const cleanUrl = location.pathname + (location.hash || '');
  history.replaceState(null, '', cleanUrl);
}

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
      populateTtsDiag(sensory);
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

  // Load the SimpleX invite QR lazily — failures shouldn't block the
  // rest of the dashboard since the feature is opt-in.
  loadSimplexInvite().catch((err) => {
    console.warn('[simplex] invite load failed:', err);
  });
}

// --- SimpleX invite QR + link -------------------------------------------
async function loadSimplexInvite() {
  const qrBox = document.getElementById('simplex-qr');
  const linkBox = document.getElementById('simplex-link-text');
  const stateBox = document.getElementById('simplex-state');
  if (!qrBox || !linkBox || !stateBox) return;

  try {
    const resp = await api('GET', '/simplex/invite');
    if (!resp || !resp.exists) {
      qrBox.innerHTML = '<span class="setting-hint">Sin link todavia</span>';
      linkBox.value = '';
      stateBox.textContent = 'simplex-chat aun no ha generado una invitacion. Revisa que el servicio este activo.';
      return;
    }
    // The daemon already rendered a full SVG string so we can drop it
    // straight in. Trusted source (same-origin) — no sanitization needed.
    if (resp.qr_svg) {
      qrBox.innerHTML = resp.qr_svg;
    } else {
      qrBox.innerHTML = '<span class="setting-hint">QR no disponible</span>';
    }
    linkBox.value = resp.link || '';
    stateBox.textContent = 'Escanea con SimpleX Chat en tu telefono para conectarte a Axi';
  } catch (err) {
    console.error('[simplex] load failed:', err);
    qrBox.innerHTML = '<span class="setting-hint">Error al cargar QR</span>';
    stateBox.textContent = 'Error: ' + (err.message || err);
  }
}

// Wire up the copy + refresh buttons once at module load.
document.addEventListener('DOMContentLoaded', () => {
  const copyBtn = document.getElementById('simplex-copy-btn');
  const refreshBtn = document.getElementById('simplex-refresh-btn');
  const linkBox = document.getElementById('simplex-link-text');
  if (copyBtn && linkBox) {
    copyBtn.addEventListener('click', async () => {
      if (!linkBox.value) return;
      try {
        await navigator.clipboard.writeText(linkBox.value);
        const prev = copyBtn.textContent;
        copyBtn.textContent = 'Copiado!';
        setTimeout(() => { copyBtn.textContent = prev; }, 1500);
      } catch (_) {
        linkBox.select();
        document.execCommand('copy');
      }
    });
  }
  if (refreshBtn) {
    refreshBtn.addEventListener('click', () => {
      loadSimplexInvite().catch((err) => console.warn('[simplex] refresh failed:', err));
    });
  }
});

// --- Periodic full state refresh (catch anything SSE missed) ---
async function refreshFullState() {
  try {
    await ensureBootstrapToken();
    const [overlay, sensory, runtime, alwaysOn, context, sysStatus] = await Promise.all([
      api('GET', '/overlay/status'),
      api('GET', '/sensory/status'),
      api('GET', '/runtime/sensory'),
      api('GET', '/runtime/always-on'),
      api('GET', '/followalong/context'),
      api('GET', '/system/status').catch(() => null),
    ]);

    // Sync the clock's timezone with whatever the daemon reports. This is
    // authoritative over the browser's detected timezone because the
    // daemon knows the host's IANA zone, while the browser may be in a
    // different environment (container, remote desktop, etc.).
    if (sysStatus?.timezone) {
      setServerTimezone(sysStatus.timezone);
    }

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
          case 'tts': populateTtsDiag(sensory); break;
          case 'screen': populateScreenDiag(sensory); break;
          case 'camera': populateCameraDiag(sensory); break;
        }
      }
      // Always update health dots
      populateAudioDiag(sensory, diagCache.stt);
      populateAlwaysOnDiag(sensory);
      populateTtsDiag(sensory);
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
function inferProviderTier(name) {
  const n = name.toLowerCase();
  if (n.startsWith('local')) return 'local';
  if (n.startsWith('cerebras') || n.startsWith('groq')) return 'free';
  if (n.startsWith('zai') || n.startsWith('kimi') || n.startsWith('minimax')) return 'cheap';
  if (n.startsWith('anthropic') || n.startsWith('openai')) return 'premium';
  return 'free';
}

function inferProviderPrivacy(name) {
  const n = name.toLowerCase();
  if (n.startsWith('local')) return { label: 'Maxima', level: 'max' };
  if (n.startsWith('cerebras') || n.startsWith('groq')) return { label: 'Alta (ZDR)', level: 'high' };
  if (n.startsWith('anthropic') || n.startsWith('openai')) return { label: 'Media (no training)', level: 'medium' };
  if (n.startsWith('gemini')) return { label: 'Baja (free entrena)', level: 'low' };
  if (n.startsWith('zai') || n.startsWith('kimi') || n.startsWith('minimax')) return { label: 'Baja (China)', level: 'low' };
  if (n.startsWith('openrouter')) return { label: 'Variable', level: 'variable' };
  return { label: '?', level: 'variable' };
}

function providerPrivacyColor(level) {
  switch (level) {
    case 'max': return 'var(--success)';
    case 'high': return 'var(--accent-2)';
    case 'medium': return 'var(--warning)';
    case 'low': return 'var(--danger)';
    default: return 'var(--text-muted)';
  }
}

async function refreshProviders() {
  try {
    const res = await fetch(`${API}/llm/providers`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const grid = $('#providers-grid');
    if (!grid || !data.providers) return;

    grid.innerHTML = data.providers.map(p => {
      const n = p.name;
      const tier = p.tier || inferProviderTier(n);
      const priv = inferProviderPrivacy(n);
      const privLabel = p.privacy_level || priv.label;
      const privLevel = priv.level;
      const model = p.model || '';
      const enabled = p.enabled !== false;
      const disabledClass = enabled ? '' : ' disabled';
      const reqCount = p.total_requests || 0;
      const errCount = p.total_failures || 0;
      const tokCount = p.total_output_tokens || 0;

      return `<div class="provider-card${disabledClass}" data-tier="${tier}" data-provider="${escapeHtml(n)}">
        <div class="provider-card-header">
          <div class="provider-name">${escapeHtml(n)}</div>
          <span class="provider-tier">${escapeHtml(tier)}</span>
        </div>
        ${model ? `<div class="provider-model-name">${escapeHtml(model)}</div>` : ''}
        <div class="provider-stats">${reqCount} req | ${tokCount} tok | ${errCount} err</div>
        <div class="provider-req-count">${reqCount} solicitudes totales</div>
        <div class="provider-stats" style="color:${providerPrivacyColor(privLevel)}">Privacidad: ${escapeHtml(privLabel)}</div>
        <div class="provider-card-actions">
          <label class="provider-toggle" title="${enabled ? 'Desactivar' : 'Activar'}">
            <input type="checkbox" ${enabled ? 'checked' : ''} onchange="toggleProvider('${escapeHtml(n)}', this.checked)">
            <span class="slider"></span>
          </label>
          <button class="provider-test-btn" onclick="testProvider('${escapeHtml(n)}')">Test</button>
          <button class="provider-test-btn" onclick="deleteProvider('${escapeHtml(n)}')" title="Eliminar entrada del TOML de usuario">X</button>
        </div>
      </div>`;
    }).join('');

    // Update key status indicators
    updateKeyStatus('cerebras', data.providers.some(p => p.name.includes('cerebras') && p.total_requests > 0));
    updateKeyStatus('groq', data.providers.some(p => p.name.includes('groq') && p.total_requests > 0));
    updateKeyStatus('zai', data.providers.some(p => p.name.includes('zai') && p.total_requests > 0));
    updateKeyStatus('openrouter', data.providers.some(p => p.name.includes('openrouter') && p.total_requests > 0));
  } catch (e) { /* silent */ }
}

// --- Provider actions ---
window.toggleProvider = async (name, enabled) => {
  try {
    const result = await api('POST', `/llm/providers/${encodeURIComponent(name)}/toggle`, {});
    addFeedItem('&#9989;', `Proveedor ${name}: ${result.state} (${result.provider_count} activos)`);
    await refreshProviders();
  } catch (err) {
    addFeedItem('&#10060;', `Toggle ${name} fallo: ${err.message}`);
    await refreshProviders();
  }
};

window.deleteProvider = async (name) => {
  if (!confirm(`Eliminar el proveedor "${name}"? Esta accion borra la entrada del TOML.`)) return;
  try {
    const result = await api('DELETE', `/llm/providers/${encodeURIComponent(name)}`);
    addFeedItem('&#9989;', `Proveedor ${name} eliminado (${result.provider_count} restantes)`);
    await refreshProviders();
  } catch (err) {
    addFeedItem('&#10060;', `Eliminar ${name} fallo: ${err.message}`);
  }
};

window.testProvider = async (name) => {
  const card = document.querySelector(`.provider-card[data-provider="${name}"]`);
  const btn = card?.querySelector('.provider-test-btn');
  if (btn) { btn.textContent = '...'; btn.disabled = true; }
  try {
    const result = await api('POST', '/llm/chat', {
      messages: [{ role: 'user', content: 'Respond with OK in one word.' }],
      provider: name
    });
    if (btn) { btn.textContent = 'OK'; btn.style.background = 'rgba(0, 212, 170, 0.3)'; }
    addFeedItem('&#9989;', `Test ${name}: OK (${result.provider || name})`);
  } catch (err) {
    if (btn) { btn.textContent = 'Fail'; btn.style.background = 'rgba(255, 71, 87, 0.3)'; }
    addFeedItem('&#10060;', `Test ${name}: ${err.message}`);
  } finally {
    if (btn) {
      btn.disabled = false;
      setTimeout(() => { btn.textContent = 'Test'; btn.style.background = ''; }, 3000);
    }
  }
};

// --- Reload providers ---
const reloadProvidersBtn = document.getElementById('reload-providers-btn');
if (reloadProvidersBtn) {
  reloadProvidersBtn.addEventListener('click', async () => {
    reloadProvidersBtn.textContent = 'Recargando...';
    try {
      await fetch(`${API}/llm/reload`, { method: 'POST', headers: apiHeaders() });
      addFeedItem('&#9989;', 'Proveedores LLM recargados');
      await refreshProviders();
    } catch (err) {
      addFeedItem('&#10060;', `Error recargando proveedores: ${err.message}`);
    } finally {
      setTimeout(() => { reloadProvidersBtn.textContent = 'Recargar proveedores'; }, 2000);
    }
  });
}

// --- Add Provider ---
window.addProvider = async () => {
  const name = $('#new-provider-name')?.value?.trim();
  const base = $('#new-provider-base')?.value?.trim();
  const model = $('#new-provider-model')?.value?.trim();
  const keyEnv = $('#new-provider-key-env')?.value?.trim();
  const tier = $('#new-provider-tier')?.value || 'free';
  const privacy = $('#new-provider-privacy')?.value || 'high';
  const hint = $('#add-provider-hint');

  if (!name || !base || !model) {
    if (hint) hint.textContent = 'Nombre, API Base y Modelo son obligatorios.';
    return;
  }

  if (hint) hint.textContent = 'Guardando...';
  try {
    const result = await api('POST', '/llm/providers', {
      name,
      api_base: base,
      model,
      api_key_env: keyEnv,
      tier,
      privacy,
    });
    if (hint) hint.textContent = `Proveedor "${name}" agregado (${result.provider_count} activos).`;
    addFeedItem('&#9989;', `Proveedor ${name} agregado`);
    ['#new-provider-name', '#new-provider-base', '#new-provider-model', '#new-provider-key-env']
      .forEach(sel => { const el = $(sel); if (el) el.value = ''; });
    await refreshProviders();
  } catch (err) {
    if (hint) hint.textContent = `Error: ${err.message}`;
    addFeedItem('&#10060;', `Agregar ${name} fallo: ${err.message}`);
  }
};

const addProviderBtn = document.getElementById('add-provider-btn');
if (addProviderBtn) {
  addProviderBtn.addEventListener('click', () => window.addProvider());
}

function updateKeyStatus(name, working) {
  const el = $(`#key-status-${name}`);
  if (!el) return;
  el.textContent = working ? '\u2705' : '\u26A0\uFE0F';
  el.classList.toggle('ok', !!working);
  el.classList.toggle('missing', !working);
}

// --- API Keys Status & Save ---
async function refreshKeyStatus() {
  try {
    const res = await fetch(`${API}/settings/keys`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const keys = data.keys || {};
    const map = {
      'ANTHROPIC_API_KEY': 'anthropic',
      'OPENAI_API_KEY': 'openai',
      'GEMINI_API_KEY': 'gemini',
      'ZAI_API_KEY': 'zai',
      'CEREBRAS_API_KEY': 'cerebras',
      'GROQ_API_KEY': 'groq',
      'OPENROUTER_API_KEY': 'openrouter',
      'LIFEOS_TELEGRAM_BOT_TOKEN': 'telegram',
      'LIFEOS_TELEGRAM_CHAT_ID': 'telegram-chatid',
    };
    for (const [env, name] of Object.entries(map)) {
      const el = $(`#key-status-${name}`);
      if (!el) continue;
      const info = keys[env] || {};
      const configured = !!info.configured;
      el.textContent = configured ? '\u2705' : '\u274C';
      el.classList.toggle('ok', configured);
      el.classList.toggle('missing', !configured);
      // Show masked hint as placeholder so user knows the saved value
      const input = $(`#key-${name}`);
      if (input && configured && info.hint) {
        input.placeholder = info.hint;
      }
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

const aiCtxInput = $('#ai-ctx-input');
const aiCtxSourceBadge = $('#ai-ctx-source-badge');
const aiCtxSaveBtn = $('#ai-ctx-save');
const aiCtxResetBtn = $('#ai-ctx-reset');
const aiCtxStatusEl = $('#ai-ctx-status');
const aiCtxVramHint = $('#ai-ctx-vram-hint');

function setCtxStatus(msg, isError) {
  if (!aiCtxStatusEl) return;
  aiCtxStatusEl.textContent = msg || '';
  aiCtxStatusEl.style.color = isError ? 'var(--error, #e74c3c)' : 'var(--text-muted)';
}

function renderCtxSourceBadge(source) {
  if (!aiCtxSourceBadge) return;
  const labels = {
    user_override: ['Override usuario', '#27ae60'],
    runtime_profile: ['Perfil hardware', '#3498db'],
    baseline: ['Default imagen', '#6b7280'],
  };
  const [label, color] = labels[source] || [source || '—', '#6b7280'];
  aiCtxSourceBadge.textContent = label;
  aiCtxSourceBadge.style.background = color;
  aiCtxSourceBadge.style.color = '#fff';
}

async function refreshLlmCtxSize() {
  try {
    const res = await fetch(`${API}/llm/ctx-size`, { headers: apiHeaders() });
    if (!res.ok) return;
    const d = await res.json();
    if (aiCtxSlider) aiCtxSlider.value = d.current_value;
    if (aiCtxValue) aiCtxValue.textContent = d.current_value;
    if (aiCtxInput) aiCtxInput.value = d.current_value;
    renderCtxSourceBadge(d.source);
    if (aiCtxVramHint) {
      const total = d.vram_total_mb ? `${d.vram_total_mb} MB` : '—';
      const free = d.vram_available_mb != null ? `${d.vram_available_mb} MB libres` : 'libre desconocido';
      const est = d.max_supported_estimate ? `${d.max_supported_estimate} tokens estimado` : 'estimacion no disponible';
      aiCtxVramHint.textContent = `VRAM total: ${total} · ${free} · max recomendado: ${est}`;
    }
  } catch (e) { /* silent */ }
}

if (aiCtxSlider) {
  aiCtxSlider.addEventListener('input', () => {
    if (aiCtxValue) aiCtxValue.textContent = aiCtxSlider.value;
    if (aiCtxInput) aiCtxInput.value = aiCtxSlider.value;
  });
}
if (aiCtxInput) {
  aiCtxInput.addEventListener('input', () => {
    if (aiCtxSlider) aiCtxSlider.value = aiCtxInput.value;
    if (aiCtxValue) aiCtxValue.textContent = aiCtxInput.value;
  });
}
if (aiCtxSaveBtn) {
  aiCtxSaveBtn.addEventListener('click', async () => {
    const value = parseInt(aiCtxInput?.value || aiCtxSlider?.value || '0', 10);
    if (!Number.isFinite(value) || value < 1024 || value > 524288) {
      setCtxStatus('Valor fuera de rango [1024, 524288]', true);
      return;
    }
    setCtxStatus('Guardando y reiniciando llama-server...', false);
    try {
      const res = await fetch(`${API}/llm/ctx-size`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...apiHeaders() },
        body: JSON.stringify({ value }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setCtxStatus(`Error: ${data.error || res.statusText}`, true);
        return;
      }
      setCtxStatus(`OK: ${data.new_value} (${data.restart_status})`, false);
      refreshLlmCtxSize();
    } catch (e) {
      setCtxStatus(`Error: ${e.message || e}`, true);
    }
  });
}
if (aiCtxResetBtn) {
  aiCtxResetBtn.addEventListener('click', async () => {
    setCtxStatus('Restaurando default y reiniciando...', false);
    try {
      const res = await fetch(`${API}/llm/ctx-size`, {
        method: 'DELETE',
        headers: apiHeaders(),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setCtxStatus(`Error: ${data.error || res.statusText}`, true);
        return;
      }
      setCtxStatus(`Restaurado: ${data.new_value} (${data.restart_status})`, false);
      refreshLlmCtxSize();
    } catch (e) {
      setCtxStatus(`Error: ${e.message || e}`, true);
    }
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
  // Pull the user-facing ctx-size config alongside the runtime status so
  // the source badge stays in sync when the benchmarker regenerates the
  // profile or when LlmConfigChanged arrives via WS.
  refreshLlmCtxSize();
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
    const path = query
      ? `${API}/memory/search?q=${encodeURIComponent(query)}&limit=10`
      : `${API}/memory/entries?limit=10`;
    const res = await fetch(path, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    const container = $('#memory-entries');
    if (!container) return;

    const entries = data.entries || data.results || [];
    if (entries.length === 0) {
      container.innerHTML = `<p class="task-empty">${query ? 'Sin resultados' : 'Sin entradas recientes'}</p>`;
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
    const result = await api('POST', '/system/mode', { mode });
    addFeedItem('&#9989;', `Modo de sistema: ${result.mode || mode}`);
  } catch (err) {
    addFeedItem('&#10060;', `Cambio de modo fallo: ${err.message}`);
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

// ==================== WORKERS ====================
const activeWorkers = new Map(); // id -> { id, task, chat_id, status, started_at }
let workerElapsedTimer = null;

function formatElapsed(startedAt) {
  if (!startedAt) return '0s';
  const sec = Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000);
  if (sec < 0) return '0s';
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m ${sec % 60}s`;
  return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
}

function renderWorkers() {
  const grid = $('#workers-grid');
  const countEl = $('#workers-count');
  if (!grid) return;

  const workers = Array.from(activeWorkers.values());
  if (countEl) countEl.textContent = workers.length;

  if (workers.length === 0) {
    grid.innerHTML = '<p class="task-empty">Sin workers activos</p>';
    return;
  }

  grid.innerHTML = workers.map(w => {
    const statusClass = `status-${w.status || 'running'}`;
    const statusLabel = { running: 'Corriendo', completed: 'Completado', failed: 'Fallido' }[w.status] || w.status || 'Corriendo';
    const elapsed = formatElapsed(w.started_at);
    const taskText = (w.task || w.objective || 'Tarea sin descripcion').substring(0, 80);
    const chatId = w.chat_id || '';
    const cancelBtn = w.status === 'running'
      ? `<button class="worker-cancel-btn" onclick="cancelWorker('${escapeHtml(w.id || '')}')">Cancelar</button>`
      : '';

    return `<div class="worker-card" data-status="${w.status || 'running'}" data-worker-id="${escapeHtml(w.id || '')}">
      <div class="worker-card-header">
        <span class="worker-task" title="${escapeHtml(w.task || w.objective || '')}">${escapeHtml(taskText)}</span>
        <span class="worker-status ${statusClass}">${statusLabel}</span>
      </div>
      <div class="worker-meta">
        ${chatId ? `<span>Chat: ${escapeHtml(String(chatId))}</span>` : ''}
        <span class="worker-elapsed" data-started="${w.started_at || ''}">${elapsed}</span>
        ${cancelBtn}
      </div>
    </div>`;
  }).join('');
}

function startWorkerElapsedTimer() {
  if (workerElapsedTimer) return;
  workerElapsedTimer = setInterval(() => {
    document.querySelectorAll('.worker-elapsed[data-started]').forEach(el => {
      const started = el.dataset.started;
      if (started) el.textContent = formatElapsed(started);
    });
  }, 1000);
}

function addWorkerCard(data) {
  const id = data.id || data.worker_id || `w-${Date.now()}`;
  activeWorkers.set(id, {
    id,
    task: data.task || data.objective || data.description || '',
    chat_id: data.chat_id || '',
    status: 'running',
    started_at: data.started_at || new Date().toISOString(),
  });
  renderWorkers();
  startWorkerElapsedTimer();
}

function updateWorkerProgress(data) {
  const id = data.id || data.worker_id;
  if (!id) return;
  const w = activeWorkers.get(id);
  if (w) {
    if (data.task || data.objective) w.task = data.task || data.objective;
    if (data.progress) w.progress = data.progress;
    renderWorkers();
  }
}

function markWorkerCompleted(data) {
  const id = data.id || data.worker_id;
  if (!id) return;
  const w = activeWorkers.get(id);
  if (w) {
    w.status = 'completed';
    renderWorkers();
    // Remove after 10s
    setTimeout(() => { activeWorkers.delete(id); renderWorkers(); }, 10000);
  }
}

function markWorkerFailed(data) {
  const id = data.id || data.worker_id;
  if (!id) return;
  const w = activeWorkers.get(id);
  if (w) {
    w.status = 'failed';
    renderWorkers();
    // Remove after 15s
    setTimeout(() => { activeWorkers.delete(id); renderWorkers(); }, 15000);
  }
}

window.cancelWorker = async (id) => {
  if (!id) return;
  try {
    await api('POST', `/workers/${encodeURIComponent(id)}/cancel`, {});
    addFeedItem('&#9989;', `Worker ${id} cancelado`);
    const w = activeWorkers.get(id);
    if (w) { w.status = 'failed'; renderWorkers(); }
  } catch (err) {
    addFeedItem('&#10060;', `Cancelar worker ${id} fallo: ${err.message}`);
  }
};

// Workers stream lifecycle events over WebSocket; GET /workers reconciles
// the local map after a page reload (or whenever the WS gets out of sync).
async function refreshWorkers() {
  try {
    const res = await fetch(`${API}/workers`, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      (data.workers || []).forEach(w => {
        if (!activeWorkers.has(w.id)) {
          activeWorkers.set(w.id, {
            id: w.id,
            task: w.task,
            chat_id: w.chat_id,
            status: w.status,
            started_at: w.started_at,
          });
        }
      });
    }
  } catch (e) { /* silent — fall back to WS-only state */ }
  renderWorkers();
  if (activeWorkers.size > 0) startWorkerElapsedTimer();
}

// --- Polling ---
setInterval(() => {
  refreshSupervisor();
  refreshTasks();
  refreshResources();
  refreshMetrics();
  refreshScheduledTasks();
  refreshWorkers();
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
  checkSafeMode();
  refreshDoctor();
  refreshConversations();
  loadCalendar();
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

// ==================== SAFE MODE ====================
const safeBanner = $('#safe-mode-banner');
const safeModeExitBtn = $('#safe-mode-exit');

async function checkSafeMode() {
  try {
    const res = await fetch(`${API}/safe-mode`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    if (safeBanner) {
      if (data.active) {
        safeBanner.classList.add('visible');
      } else {
        safeBanner.classList.remove('visible');
      }
    }
  } catch (e) { /* silent */ }
}

if (safeModeExitBtn) {
  safeModeExitBtn.addEventListener('click', async () => {
    safeModeExitBtn.textContent = 'Saliendo...';
    try {
      await fetch(`${API}/safe-mode/exit`, { method: 'POST', headers: apiHeaders() });
      safeBanner.classList.remove('visible');
      addFeedItem('&#9989;', 'Modo seguro desactivado');
    } catch (err) {
      safeModeExitBtn.textContent = 'Error';
      addFeedItem('&#10060;', `Error al salir de modo seguro: ${err.message}`);
    } finally {
      setTimeout(() => { safeModeExitBtn.textContent = 'Salir de modo seguro'; }, 2000);
    }
  });
}

// ==================== TIME & TIMEZONE DISPLAY ====================
// The dashboard fetches the daemon's timezone via /system/status on load
// and on each refreshFullState() cycle. Until it arrives we fall back to the
// browser's detected timezone. This matters because the browser and the
// daemon can disagree (e.g., container vs. host), and the user expects the
// daemon's time.
const headerClock = $('#header-clock');
const headerTz = $('#header-tz');
let serverTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

function updateClock() {
  // Render the current wall-clock time in the daemon's IANA timezone.
  // `Intl.DateTimeFormat` with `timeZone` option is the correct way to
  // force a specific zone regardless of the browser's local setting.
  try {
    const now = new Date();
    const time = new Intl.DateTimeFormat('es', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
      timeZone: serverTimezone,
    }).format(now);
    if (headerClock) headerClock.textContent = time;
    if (headerTz) headerTz.textContent = serverTimezone;
  } catch (_err) {
    // If serverTimezone is somehow invalid, fall back to browser local.
    const time = new Date().toLocaleTimeString('es', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    });
    if (headerClock) headerClock.textContent = time;
  }
}

// Sync the displayed timezone to whatever the daemon reports. Called from
// refreshFullState() after a successful /system/status fetch.
function setServerTimezone(tz) {
  if (tz && typeof tz === 'string' && tz !== serverTimezone) {
    serverTimezone = tz;
    updateClock();
  }
}

// Update clock every second
setInterval(updateClock, 1000);
updateClock();

// ==================== DOCTOR HEALTH CHECKS ====================
const doctorGrid = $('#doctor-grid');
const doctorBadge = $('#doctor-badge');
const doctorTimestamp = $('#doctor-timestamp');
const doctorRunBtn = $('#doctor-run-btn');

async function refreshDoctor() {
  try {
    const res = await fetch(`${API}/health`, { headers: apiHeaders() });
    if (!res.ok) return;
    const data = await res.json();

    if (!doctorGrid) return;

    const checks = data.checks || [];
    const overall = data.status || data.overall || 'unknown';

    // Update badge
    if (doctorBadge) {
      if (overall === 'healthy' || overall === 'ok') {
        doctorBadge.textContent = 'Saludable';
        doctorBadge.className = 'badge badge-online';
      } else if (overall === 'degraded' || overall === 'warning') {
        doctorBadge.textContent = 'Degradado';
        doctorBadge.className = 'badge badge-warn';
      } else {
        doctorBadge.textContent = 'Problemas';
        doctorBadge.className = 'badge badge-offline';
      }
    }

    if (checks.length === 0) {
      doctorGrid.innerHTML = '<p class="task-empty">Sin resultados de diagnostico</p>';
      return;
    }

    doctorGrid.innerHTML = checks.map(c => {
      const status = (c.status || '').toLowerCase();
      const cls = status === 'pass' || status === 'ok' || status === 'healthy' ? 'check-pass'
                : status === 'warn' || status === 'warning' || status === 'degraded' ? 'check-warn'
                : 'check-fail';
      const icon = cls === 'check-pass' ? '&#9989;' : cls === 'check-warn' ? '&#9888;' : '&#10060;';
      const detail = c.message || c.detail || '';
      return `<div class="doctor-check ${cls}">
        <div>
          <div class="doctor-check-name">${icon} ${escapeHtml(c.name || c.component || '?')}</div>
          <div class="doctor-check-status">${escapeHtml(c.status || '?')}</div>
          ${detail ? `<div class="doctor-check-detail">${escapeHtml(detail)}</div>` : ''}
        </div>
      </div>`;
    }).join('');

    if (doctorTimestamp) {
      doctorTimestamp.textContent = `Ultimo diagnostico: ${new Date().toLocaleTimeString('es')}`;
    }
  } catch (e) {
    if (doctorGrid) doctorGrid.innerHTML = '<p class="task-empty">Error al ejecutar diagnostico</p>';
  }
}

if (doctorRunBtn) {
  doctorRunBtn.addEventListener('click', async () => {
    doctorRunBtn.textContent = 'Ejecutando...';
    await refreshDoctor();
    doctorRunBtn.textContent = 'Ejecutar diagnostico';
  });
}

// ==================== MEETINGS HELPERS ====================

/** Convert an absolute screenshot path to a served URL via /meetings-files/ */
function meetingFileUrl(absolutePath) {
  if (!absolutePath) return '';
  // Strip the data_dir + /meetings/ prefix, leaving just the filename
  // Paths look like: /var/lib/lifeos/meetings/meeting-20260413-143000-screenshot-1.png
  const meetingsPrefix = '/meetings/';
  const idx = absolutePath.lastIndexOf(meetingsPrefix);
  if (idx !== -1) {
    const filename = absolutePath.substring(idx + meetingsPrefix.length);
    return '/meetings-files/' + encodeURIComponent(filename);
  }
  // Fallback: try just the basename
  const parts = absolutePath.split('/');
  return '/meetings-files/' + encodeURIComponent(parts[parts.length - 1]);
}

/** Lightweight screenshot lightbox */
window.openScreenshotLightbox = function(url) {
  let overlay = document.getElementById('screenshot-lightbox');
  if (!overlay) {
    overlay = document.createElement('div');
    overlay.id = 'screenshot-lightbox';
    overlay.className = 'screenshot-lightbox';
    overlay.innerHTML = '<img class="screenshot-lightbox-img" alt="Captura ampliada">';
    overlay.addEventListener('click', () => { overlay.style.display = 'none'; });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        const lb = document.getElementById('screenshot-lightbox');
        if (lb) lb.style.display = 'none';
      }
    });
    document.body.appendChild(overlay);
  }
  const img = overlay.querySelector('img');
  img.src = url;
  overlay.style.display = 'flex';
};

/** Render basic markdown: bold, italic, lists, tables, hrs, line breaks */
function renderSimpleMarkdown(text) {
  if (!text) return '';
  let html = escapeHtml(text);
  // Horizontal rule: --- or *** or ___ (full line) — must run before bold/italic
  html = html.replace(/^[\-\*_]{3,}\s*$/gm, '<hr style="border:none;border-top:1px solid var(--border);margin:8px 0">');
  // Bold: **text** or __text__
  html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/__(.+?)__/g, '<strong>$1</strong>');
  // Italic: *text* or _text_
  html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');
  html = html.replace(/(?<!\w)_(.+?)_(?!\w)/g, '<em>$1</em>');
  // Unordered list items: - item or * item at start of line
  html = html.replace(/^[\-\*]\s+(.+)$/gm, '<li>$1</li>');
  // Ordered list items: 1. item
  html = html.replace(/^\d+\.\s+(.+)$/gm, '<li>$1</li>');
  // Wrap consecutive <li> in <ul>
  html = html.replace(/((?:<li>.*<\/li>\n?)+)/g, '<ul>$1</ul>');
  // Headers: # text, ## text, ### text (order matters: ### before ## before #)
  html = html.replace(/^####\s+(.+)$/gm, '<h6 style="font-size:0.85rem;color:var(--text);margin:4px 0 2px">$1</h6>');
  html = html.replace(/^###\s+(.+)$/gm, '<h5>$1</h5>');
  html = html.replace(/^##\s+(.+)$/gm, '<h4 style="color:var(--accent);margin:8px 0 4px">$1</h4>');
  html = html.replace(/^#\s+(.+)$/gm, '<h4 style="color:var(--accent);margin:10px 0 4px;font-size:1rem">$1</h4>');

  // Markdown tables: detect consecutive lines starting with |
  html = html.replace(/((?:^\|.+\|\s*$\n?){2,})/gm, function(tableBlock) {
    const rows = tableBlock.trim().split('\n').filter(r => r.trim());
    if (rows.length < 2) return tableBlock;
    let tableHtml = '<table style="width:100%;border-collapse:collapse;font-size:0.85rem;margin:8px 0">';
    rows.forEach((row, ri) => {
      // Skip separator rows like |---|---|
      if (/^\|[\s\-:]+\|$/.test(row.trim()) || /^\|(\s*[\-:]+\s*\|)+\s*$/.test(row.trim())) return;
      const cells = row.split('|').filter((_, i, a) => i > 0 && i < a.length - 1);
      const tag = ri === 0 ? 'th' : 'td';
      const style = ri === 0
        ? 'style="text-align:left;padding:4px 8px;border-bottom:2px solid var(--border);color:var(--accent);font-weight:600"'
        : 'style="text-align:left;padding:4px 8px;border-bottom:1px solid var(--border)"';
      tableHtml += '<tr>' + cells.map(c => `<${tag} ${style}>${c.trim()}</${tag}>`).join('') + '</tr>';
    });
    tableHtml += '</table>';
    return tableHtml;
  });

  // Line breaks
  html = html.replace(/\n/g, '<br>');
  // Clean up <br> inside ul
  html = html.replace(/<br><ul>/g, '<ul>');
  html = html.replace(/<\/ul><br>/g, '</ul>');
  html = html.replace(/<\/li><br><li>/g, '</li><li>');
  // Clean up <br> around tables
  html = html.replace(/<br><table/g, '<table');
  html = html.replace(/<\/table><br>/g, '</table>');
  // Clean up <br> around hr and block elements
  html = html.replace(/<br><hr/g, '<hr');
  html = html.replace(/<hr([^>]*)><br>/g, '<hr$1>');
  html = html.replace(/<br>(<h[1-6])/g, '$1');
  html = html.replace(/(<\/h[1-6]>)<br>/g, '$1');
  return html;
}

// ==================== MEETINGS (BB.5 + BB.10 + BB.11) ====================

let meetingsCache = []; // cached meeting list for client-side filtering
let meetingsOffset = 0;
const MEETINGS_PAGE_SIZE = 10;
let meetingsCurrentPeriod = 'week';
let meetingsSearchTimer = null;
let currentMeetingDetail = null; // cached full meeting for detail view

function renderMeeting(meeting) {
  const date = meeting.started_at
    ? new Date(meeting.started_at).toLocaleDateString('es', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
    : '\u2014';
  const dur = meeting.duration_secs || 0;
  const hours = Math.floor(dur / 3600);
  const mins = Math.floor((dur % 3600) / 60);
  const durationStr = hours > 0 ? `${hours}h ${mins}m` : `${mins}m`;
  const isVideo = meeting.has_video !== false;
  const appEmoji = isVideo ? '\uD83C\uDFA5' : '\uD83C\uDF99';
  const appName = meeting.app_name || 'Desconocida';
  const pList = meeting.participants || [];
  const pCount = meeting.participants_count || pList.length || 0;
  const participants = pCount ? `${pCount} participante(s)` : '';
  const summary = meeting.summary
    ? escapeHtml(meeting.summary.substring(0, 200)) + (meeting.summary.length > 200 ? '...' : '')
    : '';
  const screenshots = meeting.screenshot_count || 0;
  const meetingId = escapeHtml(meeting.id || '');

  return `<div class="task-item" data-meeting-id="${meetingId}" onclick="showMeetingDetail('${meetingId}')">
    <div>
      <div class="task-objective">${appEmoji} ${escapeHtml(appName)} \u2014 ${date}</div>
      <div class="task-meta">${durationStr}${participants ? ' \u00B7 ' + participants : ''}${screenshots ? ' \u00B7 ' + screenshots + ' capturas' : ''}</div>
      ${summary ? `<div class="task-result">${summary}</div>` : ''}
    </div>
  </div>`;
}

function formatDateSpanish(isoStr) {
  if (!isoStr) return '\u2014';
  const d = new Date(isoStr);
  return d.toLocaleDateString('es', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
}

function formatDuration(secs) {
  if (!secs) return '0m';
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function appEmoji(appName) {
  const n = (appName || '').toLowerCase();
  if (n.includes('zoom')) return '\uD83D\uDCF9';
  if (n.includes('meet') || n.includes('google')) return '\uD83C\uDF0D';
  if (n.includes('teams')) return '\uD83D\uDCBC';
  if (n.includes('discord')) return '\uD83C\uDFAE';
  if (n.includes('slack')) return '\uD83D\uDCAC';
  return '\uD83C\uDFA5';
}

// BB.11: Filter meetings by period
function filterMeetings(period) {
  meetingsCurrentPeriod = period;
  meetingsOffset = 0;
  meetingsCache = [];

  // Update active button
  document.querySelectorAll('.meeting-filter-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.period === period);
  });

  loadMeetings();
}

// BB.11: Debounced search
function searchMeetingsDebounced(query) {
  if (meetingsSearchTimer) clearTimeout(meetingsSearchTimer);
  meetingsSearchTimer = setTimeout(() => {
    meetingsOffset = 0;
    meetingsCache = [];
    if (query && query.length >= 2) {
      searchMeetings(query);
    } else {
      loadMeetings();
    }
  }, 300);
}

async function searchMeetings(query) {
  const listEl = $('#meetings-list');
  try {
    const res = await fetch(`${API}/meetings/search?q=${encodeURIComponent(query)}&limit=${MEETINGS_PAGE_SIZE}`, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      const meetings = data.meetings || [];
      meetingsCache = meetings;
      if (listEl) {
        if (meetings.length === 0) {
          listEl.innerHTML = '<p class="task-empty">Sin resultados para la busqueda</p>';
        } else {
          listEl.innerHTML = meetings.map(renderMeeting).join('');
        }
      }
      const loadMoreEl = $('#meetings-load-more');
      if (loadMoreEl) loadMoreEl.style.display = 'none';
    } else {
      // Fallback: filter locally from cache
      if (meetingsCache.length > 0) {
        const q = query.toLowerCase();
        const filtered = meetingsCache.filter(m =>
          (m.transcript || '').toLowerCase().includes(q) ||
          (m.summary || '').toLowerCase().includes(q) ||
          (m.app_name || '').toLowerCase().includes(q)
        );
        if (listEl) {
          listEl.innerHTML = filtered.length === 0
            ? '<p class="task-empty">Sin resultados para la busqueda</p>'
            : filtered.map(renderMeeting).join('');
        }
      }
    }
  } catch (e) {
    if (listEl) listEl.innerHTML = '<p class="task-empty">Error al buscar reuniones</p>';
  }
}

async function loadMeetings(append) {
  const listEl = $('#meetings-list');
  const actionsEl = $('#meeting-action-items');
  const loadMoreEl = $('#meetings-load-more');

  // Build query params based on period filter
  let dateFrom = '';
  const now = new Date();
  if (meetingsCurrentPeriod === 'week') {
    const weekAgo = new Date(now.getTime() - 7 * 86400000);
    dateFrom = weekAgo.toISOString();
  } else if (meetingsCurrentPeriod === 'month') {
    const monthAgo = new Date(now.getTime() - 30 * 86400000);
    dateFrom = monthAgo.toISOString();
  }

  const offset = append ? meetingsOffset : 0;
  if (!append) meetingsOffset = 0;

  // Fetch meetings
  try {
    let url = `${API}/meetings/recent?limit=${MEETINGS_PAGE_SIZE}&offset=${offset}`;
    if (dateFrom) url += `&from=${encodeURIComponent(dateFrom)}`;
    const res = await fetch(url, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      const meetings = data.meetings || [];
      if (append) {
        meetingsCache = meetingsCache.concat(meetings);
      } else {
        meetingsCache = meetings;
      }
      if (listEl) {
        if (meetingsCache.length === 0) {
          listEl.innerHTML = '<p class="task-empty">Sin reuniones recientes</p>';
        } else {
          listEl.innerHTML = meetingsCache.map(renderMeeting).join('');
        }
      }
      meetingsOffset = meetingsCache.length;
      // Show/hide load more
      if (loadMoreEl) {
        loadMoreEl.style.display = meetings.length >= MEETINGS_PAGE_SIZE ? '' : 'none';
      }
    } else if (res.status === 404) {
      if (listEl) listEl.innerHTML = '<p class="task-empty">Sin datos de reuniones</p>';
      if (loadMoreEl) loadMoreEl.style.display = 'none';
    }
  } catch (e) {
    if (listEl && !append) listEl.innerHTML = '<p class="task-empty">Sin datos de reuniones</p>';
    if (loadMoreEl) loadMoreEl.style.display = 'none';
  }

  // Fetch meeting stats
  try {
    const res = await fetch(`${API}/meetings/stats`, { headers: apiHeaders() });
    if (res.ok) {
      const stats = await res.json();
      const totalEl = $('#mtg-total');
      const hoursEl = $('#mtg-hours');
      const avgEl = $('#mtg-avg');
      const topEl = $('#mtg-top-participant');
      if (totalEl) totalEl.textContent = stats.total_meetings || stats.meetings_this_month || 0;
      if (hoursEl) {
        const h = stats.total_hours || 0;
        hoursEl.textContent = h >= 1 ? `${h.toFixed(1)}h` : `${Math.round(h * 60)}m`;
      }
      if (avgEl) {
        const avg = stats.avg_duration_mins || stats.avg_duration_minutes || 0;
        avgEl.textContent = avg >= 60 ? `${Math.floor(avg / 60)}h ${Math.round(avg % 60)}m` : `${Math.round(avg)}m`;
      }
      if (topEl) topEl.textContent = stats.top_participant || '\u2014';
    }
  } catch (e) { /* silent */ }

  // Fetch action items
  try {
    const res = await fetch(`${API}/meetings/action-items`, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      const items = data.action_items || [];
      if (actionsEl) {
        if (items.length === 0) {
          actionsEl.innerHTML = '<p class="task-empty">Sin action items pendientes</p>';
        } else {
          actionsEl.innerHTML = items.map(item => {
            const who = item.assignee || item.who || 'Sin asignar';
            const what = item.description || item.what || '';
            const when = (item.due_date || item.when) ? ` \u00B7 ${escapeHtml(item.due_date || item.when)}` : '';
            const done = item.completed ? '\u2705' : '\u23F3';
            return `<div class="task-item"><div><div class="task-objective">${done} ${escapeHtml(what)}</div><div class="task-meta">${escapeHtml(who)}${when}</div></div></div>`;
          }).join('');
        }
      }
    } else if (res.status === 404) {
      if (actionsEl) actionsEl.innerHTML = '<p class="task-empty">Sin action items pendientes</p>';
    }
  } catch (e) {
    if (actionsEl) actionsEl.innerHTML = '<p class="task-empty">Sin action items pendientes</p>';
  }
}

// BB.11: Filter bar event listeners
document.querySelectorAll('.meeting-filter-btn').forEach(btn => {
  btn.addEventListener('click', () => filterMeetings(btn.dataset.period));
});

const meetingSearchInput = $('#meeting-search-input');
if (meetingSearchInput) {
  meetingSearchInput.addEventListener('input', (e) => {
    searchMeetingsDebounced(e.target.value.trim());
  });
}

const meetingsLoadMoreBtn = $('#meetings-load-more-btn');
if (meetingsLoadMoreBtn) {
  meetingsLoadMoreBtn.addEventListener('click', () => loadMeetings(true));
}

// ==================== BB.10: MEETING DETAIL VIEW ====================

window.showMeetingDetail = async function(meetingId) {
  if (!meetingId) return;
  const detailEl = $('#meeting-detail');
  const listEl = $('#meetings-list');
  if (!detailEl) return;

  // Try to find meeting in cache first
  let meeting = meetingsCache.find(m => m.id === meetingId);

  // Fetch full meeting data (cache may only have summary fields)
  try {
    const res = await fetch(`${API}/meetings/${encodeURIComponent(meetingId)}`, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      meeting = data.meeting || data;
    } else if (!meeting) {
      addFeedItem('&#10060;', 'Error al cargar detalle de reunion');
      return;
    }
  } catch (e) {
    if (!meeting) {
      addFeedItem('&#10060;', 'Error al cargar detalle de reunion');
      return;
    }
  }

  currentMeetingDetail = meeting;

  // Populate header
  const titleEl = $('#md-title');
  const dateEl = $('#md-date');
  const durEl = $('#md-duration');
  const appEl = $('#md-app');
  if (titleEl) titleEl.textContent = meeting.summary
    ? meeting.summary.substring(0, 80)
    : (meeting.app_name || 'Reunion');
  if (dateEl) dateEl.textContent = formatDateSpanish(meeting.started_at);
  if (durEl) durEl.textContent = formatDuration(meeting.duration_secs);
  if (appEl) appEl.textContent = `${appEmoji(meeting.app_name)} ${meeting.app_name || 'Desconocida'}`;

  // Participants
  const partEl = $('#md-participants');
  const partSection = $('#md-participants-section');
  const participants = meeting.participants || [];
  if (partEl) {
    if (participants.length > 0) {
      partEl.textContent = participants.join(', ');
      if (partSection) partSection.style.display = '';
    } else {
      partEl.textContent = 'No detectados';
      if (partSection) partSection.style.display = '';
    }
  }

  // Summary — render basic markdown
  const summaryEl = $('#md-summary');
  if (summaryEl) {
    const rawSummary = meeting.summary || 'Sin resumen disponible';
    summaryEl.innerHTML = renderSimpleMarkdown(rawSummary);
  }

  // Action items
  const actionsEl = $('#md-action-items');
  const actionsSection = $('#md-actions-section');
  const actionItems = meeting.action_items || [];
  if (actionsEl) {
    if (actionItems.length > 0) {
      actionsEl.innerHTML = renderActionItems(actionItems);
      if (actionsSection) actionsSection.style.display = '';
    } else {
      actionsEl.innerHTML = '<span style="color:var(--text-muted)">Sin action items</span>';
      if (actionsSection) actionsSection.style.display = '';
    }
  }

  // Transcript — collapsible
  const transcriptEl = $('#md-transcript');
  const transcriptSection = $('#md-transcript-section');
  const diarized = meeting.diarized_transcript || '';
  const plainTranscript = meeting.transcript || '';
  if (transcriptEl) {
    let transcriptHtml = '';
    if (diarized) {
      transcriptHtml = renderTranscript(diarized);
    } else if (plainTranscript) {
      transcriptHtml = `<div class="transcript-line speaker-1"><span class="speaker-name">[Transcripcion]</span> ${escapeHtml(plainTranscript)}</div>`;
    }
    if (transcriptHtml) {
      transcriptEl.innerHTML = `<details class="transcript-collapsible"><summary class="transcript-toggle">Mostrar transcripcion completa</summary><div class="transcript-content">${transcriptHtml}</div></details>`;
      if (transcriptSection) transcriptSection.style.display = '';
    } else {
      transcriptEl.innerHTML = '<span style="color:var(--text-muted)">Sin transcripcion disponible</span>';
      if (transcriptSection) transcriptSection.style.display = '';
    }
  }

  // Screenshots — convert absolute paths to the served /meetings-files/ URL
  const screenshotsEl = $('#md-screenshots');
  const screenshotsSection = $('#md-screenshots-section');
  const paths = meeting.screenshot_paths || [];
  if (screenshotsEl && screenshotsSection) {
    if (paths.length > 0) {
      screenshotsEl.innerHTML = paths.map(p => {
        const url = meetingFileUrl(p);
        return `<img src="${escapeHtml(url)}" alt="Captura" loading="lazy" onclick="openScreenshotLightbox('${escapeHtml(url)}')" onerror="this.style.display='none'">`;
      }).join('');
      screenshotsSection.style.display = '';
    } else {
      screenshotsSection.style.display = 'none';
    }
  }

  // Show detail, hide list
  detailEl.style.display = '';
  if (listEl) listEl.style.display = 'none';
  const filterBar = $('#meeting-filter-bar');
  if (filterBar) filterBar.style.display = 'none';
  const loadMore = $('#meetings-load-more');
  if (loadMore) loadMore.style.display = 'none';
};

function renderTranscript(text) {
  if (!text) return '';
  const lines = text.split('\n').filter(l => l.trim());
  const speakerMap = {};
  let speakerCount = 0;

  return lines.map(line => {
    // Try to parse diarized format: "[Speaker Name] HH:MM — text" or "Speaker Name: text"
    let speaker = '';
    let timestamp = '';
    let content = line;

    // Pattern: [Name] HH:MM — text
    const m1 = line.match(/^\[([^\]]+)\]\s*(\d{1,2}:\d{2})?\s*[\u2014\-]?\s*(.*)/);
    if (m1) {
      speaker = m1[1];
      timestamp = m1[2] || '';
      content = m1[3] || '';
    } else {
      // Pattern: Name: text
      const m2 = line.match(/^([A-Za-z\u00C0-\u024F\s]+?):\s*(.*)/);
      if (m2 && m2[1].length < 30) {
        speaker = m2[1].trim();
        content = m2[2] || '';
      }
    }

    if (speaker && !speakerMap[speaker]) {
      speakerCount++;
      speakerMap[speaker] = speakerCount;
    }
    const speakerIdx = speakerMap[speaker] || 1;
    const cls = `speaker-${Math.min(speakerIdx, 6)}`;

    if (speaker) {
      return `<div class="transcript-line ${cls}"><span class="speaker-name">[${escapeHtml(speaker)}]</span>${timestamp ? ` <span class="timestamp">${escapeHtml(timestamp)}</span>` : ''} \u2014 ${escapeHtml(content)}</div>`;
    } else {
      return `<div class="transcript-line speaker-1">${escapeHtml(content)}</div>`;
    }
  }).join('');
}

function renderActionItems(items) {
  if (!items || items.length === 0) return '';
  return items.map((item, idx) => {
    const checked = item.completed ? 'checked' : '';
    const who = item.who || item.assignee || 'Sin asignar';
    const what = item.what || item.description || '';
    const when = item.when || item.due_date || '';
    return `<div class="action-item">
      <input type="checkbox" ${checked} disabled>
      <span class="action-item-who">${escapeHtml(who)}</span>
      <span class="action-item-what">${escapeHtml(what)}</span>
      ${when ? `<span class="action-item-when">${escapeHtml(when)}</span>` : ''}
    </div>`;
  }).join('');
}

function exportMeetingMarkdown(meeting) {
  if (!meeting) return;
  const lines = [];
  lines.push(`# ${meeting.summary || meeting.app_name || 'Reunion'}`);
  lines.push('');
  lines.push(`**Fecha:** ${formatDateSpanish(meeting.started_at)}`);
  lines.push(`**Duracion:** ${formatDuration(meeting.duration_secs)}`);
  lines.push(`**App:** ${meeting.app_name || 'Desconocida'}`);
  const parts = meeting.participants || [];
  lines.push(`**Participantes:** ${parts.length > 0 ? parts.join(', ') : 'No detectados'}`);
  lines.push('');

  if (meeting.summary) {
    lines.push('## Resumen');
    lines.push('');
    lines.push(meeting.summary);
    lines.push('');
  }

  const items = meeting.action_items || [];
  if (items.length > 0) {
    lines.push('## Action Items');
    lines.push('');
    items.forEach(item => {
      const check = item.completed ? 'x' : ' ';
      const who = item.who || item.assignee || '';
      const what = item.what || item.description || '';
      const when = item.when || item.due_date || '';
      lines.push(`- [${check}] **${who}**: ${what}${when ? ` (${when})` : ''}`);
    });
    lines.push('');
  }

  const transcript = meeting.diarized_transcript || meeting.transcript || '';
  if (transcript) {
    lines.push('## Transcripcion');
    lines.push('');
    lines.push(transcript);
    lines.push('');
  }

  const md = lines.join('\n');
  const blob = new Blob([md], { type: 'text/markdown;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  const dateSlug = meeting.started_at ? meeting.started_at.substring(0, 10) : 'reunion';
  a.href = url;
  a.download = `reunion-${dateSlug}-${(meeting.id || '').substring(0, 8)}.md`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function closeMeetingDetail() {
  const detailEl = $('#meeting-detail');
  const listEl = $('#meetings-list');
  const filterBar = $('#meeting-filter-bar');
  const loadMore = $('#meetings-load-more');
  if (detailEl) detailEl.style.display = 'none';
  if (listEl) listEl.style.display = '';
  if (filterBar) filterBar.style.display = '';
  // Restore load more only if there were enough items
  if (loadMore && meetingsCache.length >= MEETINGS_PAGE_SIZE) loadMore.style.display = '';
  currentMeetingDetail = null;
}

// Detail panel event listeners
const meetingDetailClose = $('#meeting-detail-close');
if (meetingDetailClose) {
  meetingDetailClose.addEventListener('click', closeMeetingDetail);
}

const mdExportBtn = $('#md-export-btn');
if (mdExportBtn) {
  mdExportBtn.addEventListener('click', () => {
    if (currentMeetingDetail) exportMeetingMarkdown(currentMeetingDetail);
  });
}

// ==================== CONVERSATION HISTORY ====================
const conversationList = $('#conversation-list');

// Unified conversation history. Backend reads
// ~/.local/share/lifeos/conversation_history.json and tags each entry
// with the inferred source (telegram | simplex). The UI lists them and
// fetches the full message thread on click.
async function refreshConversations() {
  if (!conversationList) return;
  try {
    const res = await fetch(`${API}/conversations?limit=20`, { headers: apiHeaders() });
    if (!res.ok) {
      conversationList.innerHTML = '<p class="task-empty">No se pudo cargar el historial.</p>';
      return;
    }
    const data = await res.json();
    const convos = (data.conversations || []).map(c => ({
      id: c.chat_id,
      source: c.source,
      preview: c.preview,
      message_count: c.message_count,
      updated_at: c.last_active,
      messages: [],
    }));
    renderConversations(convos);
    conversationList.querySelectorAll('.conversation-item').forEach((item, idx) => {
      item.addEventListener('click', async () => {
        const conv = convos[idx];
        if (!conv || conv.messages.length > 0) return;
        try {
          const detail = await api('GET', `/conversations/${conv.id}`);
          conv.messages = detail.messages || [];
          renderConversations(convos);
        } catch (e) { /* silent */ }
      }, { once: true });
    });
  } catch (e) {
    conversationList.innerHTML = `<p class="task-empty">Error: ${e.message}</p>`;
  }
}

function renderConversations(convos) {
  if (!conversationList) return;
  if (!convos || convos.length === 0) {
    conversationList.innerHTML = '<p class="task-empty">Sin conversaciones recientes</p>';
    return;
  }

  conversationList.innerHTML = convos.map((c, idx) => {
    const source = c.source || c.channel || 'desconocido';
    const time = c.updated_at || c.created_at || c.timestamp || '';
    const preview = c.preview || c.last_message || c.summary || '';
    const messages = c.messages || [];
    const msgCount = c.message_count || messages.length || 0;

    let transcriptHtml = '';
    if (messages.length > 0) {
      transcriptHtml = messages.map(m => {
        const role = (m.role || 'user').toLowerCase();
        const cls = role === 'assistant' || role === 'axi' ? 'transcript-msg-axi' : 'transcript-msg-user';
        const roleName = role === 'assistant' || role === 'axi' ? 'Axi' : 'Tu';
        return `<div class="transcript-msg ${cls}">
          <div class="transcript-msg-role">${roleName}</div>
          ${escapeHtml((m.content || '').substring(0, 500))}
        </div>`;
      }).join('');
    }

    return `<div class="conversation-item" data-conv-idx="${idx}">
      <div class="conversation-header">
        <span class="conversation-source">${escapeHtml(source)}${msgCount ? ` (${msgCount} msgs)` : ''}</span>
        <span class="conversation-time">${time ? timeAgo(time) : ''}</span>
      </div>
      ${preview ? `<div class="conversation-preview">${escapeHtml(preview.substring(0, 120))}</div>` : ''}
      ${transcriptHtml ? `<div class="conversation-transcript">${transcriptHtml}</div>` : ''}
    </div>`;
  }).join('');

  // Add click to expand
  conversationList.querySelectorAll('.conversation-item').forEach(item => {
    item.addEventListener('click', () => {
      const wasExpanded = item.classList.contains('expanded');
      conversationList.querySelectorAll('.conversation-item.expanded').forEach(i => i.classList.remove('expanded'));
      if (!wasExpanded) item.classList.add('expanded');
    });
  });
}

// --- Sidebar Navigation ---
function initSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  const hamburger = document.getElementById('hamburger-btn');
  if (!sidebar) return;

  function closeMobileSidebar() {
    if (window.innerWidth <= 768) {
      sidebar.classList.remove('open');
      overlay.classList.remove('visible');
    }
  }

  function clearAllActive() {
    document.querySelectorAll('.sidebar-nav-item').forEach(b => {
      b.classList.remove('active');
      b.classList.remove('parent-active');
    });
    document.querySelectorAll('.sidebar-submenu-item').forEach(b => b.classList.remove('active'));
  }

  function showSection(sectionId) {
    document.querySelectorAll('.content-section').forEach(s => {
      s.classList.remove('active');
      s.classList.remove('subsection-filtered');
    });
    const target = document.getElementById('section-' + sectionId);
    if (target) {
      target.classList.add('active');
      // Clear any subsection visibility
      target.querySelectorAll('[data-subsection]').forEach(el => el.classList.remove('subsection-visible'));
    }
    const main = document.querySelector('main');
    if (main) main.scrollTop = 0;
  }

  function showSubsection(sectionId, subsectionName) {
    const target = document.getElementById('section-' + sectionId);
    if (!target) return;
    // Show the parent content-section
    document.querySelectorAll('.content-section').forEach(s => {
      s.classList.remove('active');
      s.classList.remove('subsection-filtered');
    });
    target.classList.add('active');
    target.classList.add('subsection-filtered');
    // Show only matching subsection elements
    target.querySelectorAll('[data-subsection]').forEach(el => {
      if (el.dataset.subsection === subsectionName) {
        el.classList.add('subsection-visible');
      } else {
        el.classList.remove('subsection-visible');
      }
    });
    const main = document.querySelector('main');
    if (main) main.scrollTop = 0;
  }

  // Direct nav items (no submenu) — Inicio, Axi Chat
  document.querySelectorAll('.sidebar-nav-item:not(.has-submenu)').forEach(btn => {
    btn.addEventListener('click', () => {
      const section = btn.dataset.section;
      if (!section) return;
      clearAllActive();
      btn.classList.add('active');
      // Collapse all submenu groups
      document.querySelectorAll('.sidebar-nav-group').forEach(g => g.classList.remove('expanded'));
      showSection(section);
      closeMobileSidebar();
    });
  });

  // Parent items with submenus
  document.querySelectorAll('.sidebar-nav-item.has-submenu').forEach(btn => {
    btn.addEventListener('click', () => {
      const section = btn.dataset.section;
      if (!section) return;
      const group = btn.closest('.sidebar-nav-group');
      if (!group) return;

      const wasExpanded = group.classList.contains('expanded');

      if (wasExpanded) {
        // Collapse this group
        group.classList.remove('expanded');
      } else {
        // Expand this group, collapse others
        document.querySelectorAll('.sidebar-nav-group').forEach(g => g.classList.remove('expanded'));
        group.classList.add('expanded');

        // Auto-select first child if no child is currently active
        const activeChild = group.querySelector('.sidebar-submenu-item.active');
        if (!activeChild) {
          const firstChild = group.querySelector('.sidebar-submenu-item');
          if (firstChild) {
            firstChild.click();
            return; // The child click handler takes care of everything
          }
        } else {
          // Re-show the active child's subsection
          clearAllActive();
          btn.classList.add('parent-active');
          activeChild.classList.add('active');
          showSubsection(section, activeChild.dataset.subsectionTarget);
        }
      }
    });
  });

  // Submenu items
  document.querySelectorAll('.sidebar-submenu-item').forEach(btn => {
    btn.addEventListener('click', () => {
      const parentSection = btn.dataset.parent;
      const subsection = btn.dataset.subsectionTarget;
      if (!parentSection || !subsection) return;

      clearAllActive();

      // Set parent as parent-active
      const parentBtn = document.querySelector(`.sidebar-nav-item[data-section="${parentSection}"]`);
      if (parentBtn) parentBtn.classList.add('parent-active');

      // Set this submenu item as active
      btn.classList.add('active');

      // Ensure the group is expanded
      const group = btn.closest('.sidebar-nav-group');
      if (group) group.classList.add('expanded');

      showSubsection(parentSection, subsection);
      closeMobileSidebar();
    });
  });

  if (hamburger) {
    hamburger.addEventListener('click', () => {
      sidebar.classList.toggle('open');
      overlay.classList.toggle('visible');
    });
  }
  if (overlay) {
    overlay.addEventListener('click', () => {
      sidebar.classList.remove('open');
      overlay.classList.remove('visible');
    });
  }

  // --- Persist active section across reloads ---
  function saveNavState(section, subsection) {
    const state = { section };
    if (subsection) state.subsection = subsection;
    localStorage.setItem('lifeos_nav', JSON.stringify(state));
    // Update URL hash without triggering navigation
    const hash = subsection ? `${section}/${subsection}` : section;
    history.replaceState(null, '', `#${hash}`);
  }

  // Patch all nav handlers to persist state
  document.querySelectorAll('.sidebar-nav-item:not(.has-submenu)').forEach(btn => {
    btn.addEventListener('click', () => saveNavState(btn.dataset.section));
  });
  document.querySelectorAll('.sidebar-submenu-item').forEach(btn => {
    btn.addEventListener('click', () => saveNavState(btn.dataset.parent, btn.dataset.subsectionTarget));
  });

  // Restore saved state on load
  function restoreNavState() {
    // Priority: URL hash > localStorage > default (inicio)
    let section = null, subsection = null;
    const hash = location.hash.replace('#', '');
    if (hash) {
      const parts = hash.split('/');
      section = parts[0];
      subsection = parts[1] || null;
    } else {
      try {
        const saved = JSON.parse(localStorage.getItem('lifeos_nav'));
        if (saved && saved.section) {
          section = saved.section;
          subsection = saved.subsection || null;
        }
      } catch (_) {}
    }
    if (!section) return; // Default inicio is already shown

    if (subsection) {
      // Find and click the submenu item
      const subBtn = document.querySelector(`.sidebar-submenu-item[data-parent="${section}"][data-subsection-target="${subsection}"]`);
      if (subBtn) { subBtn.click(); return; }
    }
    // Click the main nav item
    const navBtn = document.querySelector(`.sidebar-nav-item[data-section="${section}"]`);
    if (navBtn) navBtn.click();
  }

  restoreNavState();

  // Sync mobile connection badge
  const connBadge = document.getElementById('connection-badge');
  const connBadgeMobile = document.getElementById('connection-badge-mobile');
  if (connBadge && connBadgeMobile) {
    const observer = new MutationObserver(() => {
      connBadgeMobile.textContent = connBadge.textContent;
      connBadgeMobile.className = connBadge.className;
    });
    observer.observe(connBadge, { attributes: true, childList: true, characterData: true });
  }
}

// Keep old name as alias so nothing breaks
function initTabs() { initSidebar(); }

// --- Calendar ---
const calendarGrid = $('#calendar-grid');
const calendarTodayEvents = $('#calendar-today-events');
const calendarUpcomingEvents = $('#calendar-upcoming-events');
const calendarMonthLabel = $('#calendar-month-label');
const calendarAddForm = $('#calendar-add-form');

function renderCalendarEvent(event) {
  const item = document.createElement('div');
  item.className = 'calendar-event-item';
  const time = document.createElement('span');
  time.className = 'calendar-event-time';
  if (event.start_time) {
    const d = new Date(event.start_time);
    time.textContent = d.toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' });
  } else {
    time.textContent = '--:--';
  }
  const title = document.createElement('span');
  title.className = 'calendar-event-title';
  title.textContent = event.title || 'Sin titulo';
  item.append(time, title);
  if (event.reminder_minutes != null) {
    const badge = document.createElement('span');
    badge.className = 'calendar-event-badge';
    badge.textContent = `${event.reminder_minutes}m`;
    item.append(badge);
  }
  return item;
}

function renderCalendarGrid(events) {
  if (!calendarGrid) return;
  const now = new Date();
  const year = now.getFullYear();
  const month = now.getMonth();
  const todayDate = now.getDate();

  const monthNames = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
  if (calendarMonthLabel) calendarMonthLabel.textContent = `${monthNames[month]} ${year}`;

  // Collect days with events
  const eventDays = new Set();
  (events || []).forEach(ev => {
    if (ev.start_time) {
      const d = new Date(ev.start_time);
      if (d.getMonth() === month && d.getFullYear() === year) {
        eventDays.add(d.getDate());
      }
    }
  });

  // Remove old day cells (keep headers)
  const headers = calendarGrid.querySelectorAll('.calendar-day-header');
  calendarGrid.innerHTML = '';
  headers.forEach(h => calendarGrid.appendChild(h));

  const firstDay = new Date(year, month, 1);
  // Monday = 0 ... Sunday = 6
  let startOffset = (firstDay.getDay() + 6) % 7;
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const prevMonthDays = new Date(year, month, 0).getDate();

  // Previous month filler
  for (let i = startOffset - 1; i >= 0; i--) {
    const cell = document.createElement('span');
    cell.className = 'calendar-day calendar-other-month';
    cell.textContent = prevMonthDays - i;
    calendarGrid.appendChild(cell);
  }

  // Current month days
  for (let d = 1; d <= daysInMonth; d++) {
    const cell = document.createElement('span');
    let cls = 'calendar-day';
    if (d === todayDate) cls += ' calendar-today';
    if (eventDays.has(d)) cls += ' calendar-has-event';
    cell.className = cls;
    cell.textContent = d;
    calendarGrid.appendChild(cell);
  }

  // Next month filler
  const totalCells = startOffset + daysInMonth;
  const remainder = totalCells % 7;
  if (remainder > 0) {
    for (let i = 1; i <= 7 - remainder; i++) {
      const cell = document.createElement('span');
      cell.className = 'calendar-day calendar-other-month';
      cell.textContent = i;
      calendarGrid.appendChild(cell);
    }
  }
}

async function loadCalendar() {
  let todayEvents = [];
  let upcomingEvents = [];

  try {
    const res = await fetch(`${API}/calendar/today`, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      todayEvents = data.events || data || [];
    }
  } catch (e) { /* silent */ }

  try {
    const res = await fetch(`${API}/calendar/upcoming?days=7`, { headers: apiHeaders() });
    if (res.ok) {
      const data = await res.json();
      upcomingEvents = data.events || data || [];
    }
  } catch (e) { /* silent */ }

  // Render today events
  if (calendarTodayEvents) {
    if (Array.isArray(todayEvents) && todayEvents.length > 0) {
      calendarTodayEvents.innerHTML = '';
      todayEvents.forEach(ev => calendarTodayEvents.appendChild(renderCalendarEvent(ev)));
    } else {
      calendarTodayEvents.innerHTML = '<p class="task-empty">Sin eventos hoy</p>';
    }
  }

  // Render upcoming events
  if (calendarUpcomingEvents) {
    if (Array.isArray(upcomingEvents) && upcomingEvents.length > 0) {
      calendarUpcomingEvents.innerHTML = '';
      upcomingEvents.forEach(ev => calendarUpcomingEvents.appendChild(renderCalendarEvent(ev)));
    } else {
      calendarUpcomingEvents.innerHTML = '<p class="task-empty">Sin eventos proximos</p>';
    }
  }

  // Render calendar grid with all events merged
  const allEvents = [...todayEvents, ...upcomingEvents];
  renderCalendarGrid(allEvents);
}

async function addCalendarEvent(e) {
  e.preventDefault();
  const titleInput = $('#cal-event-title');
  const dateInput = $('#cal-event-date');
  if (!titleInput || !dateInput) return;
  const title = titleInput.value.trim();
  const startTime = dateInput.value;
  if (!title || !startTime) return;

  try {
    const res = await fetch(`${API}/calendar/events`, {
      method: 'POST',
      headers: apiHeaders(),
      body: JSON.stringify({
        title,
        start_time: new Date(startTime).toISOString(),
        reminder_minutes: 15,
      }),
    });
    if (res.ok) {
      titleInput.value = '';
      dateInput.value = '';
      await loadCalendar();
      addFeedItem('&#128197;', `Evento agregado: ${title}`);
    } else {
      const err = await res.json().catch(() => ({}));
      console.warn('Failed to add calendar event:', err.message || res.statusText);
    }
  } catch (e) {
    console.warn('Calendar add event failed:', e);
  }
}

if (calendarAddForm) {
  calendarAddForm.addEventListener('submit', addCalendarEvent);
}

// ==================== VIDA PLENA ====================
const VP_PILLARS = [
  { key: 'health',        label: 'Salud',        stat: s => `${(s.facts||[]).length} hechos, ${(s.active_medications||[]).length} medicamentos` },
  { key: 'growth',        label: 'Crecimiento',  stat: s => `${(s.currently_reading||[]).length} leyendo, ${(s.active_habits||[]).length} habitos` },
  { key: 'exercise',      label: 'Ejercicio',    stat: s => `${s.sessions_last_7_days||0} sesiones (7d), ${s.total_minutes_last_30_days||0} min (30d)` },
  { key: 'nutrition',     label: 'Nutricion',    stat: s => `${(s.recent_logs||[]).length} registros recientes` },
  { key: 'social',        label: 'Social',       stat: s => `${(s.recent_interactions||[]).length} interacciones` },
  { key: 'sleep',         label: 'Sueno',        stat: s => `${(s.recent_logs||[]).length} registros` },
  { key: 'spiritual',     label: 'Espiritual',   stat: s => `${(s.recent_entries||s.practices||[]).length} practicas` },
  { key: 'financial',     label: 'Finanzas',     stat: s => `${(s.recent_transactions||[]).length} transacciones` },
  { key: 'relationships', label: 'Relaciones',   stat: s => `${(s.contacts||s.people||[]).length} contactos` },
];

async function refreshVidaPlena() {
  const summaryEl = $('#vida-plena-summary');
  const habitsEl = $('#vida-plena-habits');
  const moodEl = $('#vida-plena-mood');
  if (!summaryEl) return;

  // Life summary (unified coaching snapshot)
  try {
    const data = await api('GET', '/vida-plena/life-summary');
    const s = data && data.summary;
    if (s) {
      const cards = VP_PILLARS.map(p => {
        const pillarData = s[p.key];
        if (!pillarData) return '';
        let detail = '';
        try { detail = p.stat(pillarData); } catch {}
        return `<div class="vida-plena-card clickable" data-pillar="${p.key}" data-label="${p.label}" role="button" tabindex="0">
          <span class="pillar-name">${p.label}</span>
          <span class="pillar-detail">${detail || 'Sin datos'}</span>
        </div>`;
      }).filter(Boolean);
      summaryEl.innerHTML = cards.join('') || '<p class="task-empty">Sin datos de vida plena aun</p>';
      summaryEl.querySelectorAll('.vida-plena-card.clickable').forEach(el => {
        el.addEventListener('click', () => openVpPillarDetail(el.dataset.pillar, el.dataset.label));
        el.addEventListener('keydown', (ev) => {
          if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); openVpPillarDetail(el.dataset.pillar, el.dataset.label); }
        });
      });
    } else {
      summaryEl.innerHTML = '<p class="task-empty">Sin datos de vida plena aun</p>';
    }
  } catch (e) {
    summaryEl.innerHTML = '<p class="task-empty">Error cargando resumen de vida plena</p>';
  }

  // Habits due today
  if (habitsEl) {
    try {
      const data = await api('GET', '/vida-plena/habits/due-today');
      const habits = data.habits || data || [];
      if (Array.isArray(habits) && habits.length > 0) {
        habitsEl.innerHTML = '<h3>Habitos de hoy</h3>' + habits.map(h =>
          `<div class="habit-item"><span>${h.completed ? '&#9989;' : '&#9744;'}</span><span>${h.name || h.habit_id || 'Habito'}</span></div>`
        ).join('');
      } else {
        habitsEl.innerHTML = '';
      }
    } catch { habitsEl.innerHTML = ''; }
  }

  // Mood streak
  if (moodEl) {
    try {
      const data = await api('GET', '/vida-plena/mood-streak');
      if (data && data.streak != null) {
        moodEl.innerHTML = `<div class="mood-item"><span>Racha de animo:</span><span class="mood-streak">${data.streak} dias</span></div>`;
      } else {
        moodEl.innerHTML = '';
      }
    } catch { moodEl.innerHTML = ''; }
  }
}

// --- Vida Plena: per-pillar detail view ---
const VP_PILLAR_PATHS = {
  health:        '/vida-plena/health/summary',
  growth:        '/vida-plena/growth/summary',
  exercise:      '/vida-plena/exercise/summary',
  nutrition:     '/vida-plena/nutrition/summary',
  social:        '/vida-plena/social/summary',
  sleep:         '/vida-plena/sleep/summary',
  spiritual:     '/vida-plena/spiritual/summary',
  financial:     '/vida-plena/financial/summary',
  relationships: '/vida-plena/relationships/summary',
};

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

function renderPillarDetail(label, summary) {
  if (!summary || typeof summary !== 'object') {
    return `<p class="task-empty">Sin datos para ${escapeHtml(label)}.</p>`;
  }
  const entries = Object.entries(summary);
  if (entries.length === 0) {
    return `<p class="task-empty">Sin datos para ${escapeHtml(label)}.</p>`;
  }
  const rows = entries.map(([k, v]) => {
    let display;
    if (Array.isArray(v)) {
      display = `<em>${v.length} elementos</em>`;
      if (v.length > 0 && v.length <= 25) {
        display += `<pre>${escapeHtml(JSON.stringify(v, null, 2))}</pre>`;
      }
    } else if (v && typeof v === 'object') {
      display = `<pre>${escapeHtml(JSON.stringify(v, null, 2))}</pre>`;
    } else {
      display = escapeHtml(v);
    }
    return `<div class="vp-detail-row"><strong>${escapeHtml(k)}:</strong> ${display}</div>`;
  });
  return `<div class="vp-detail-body">${rows.join('')}</div>`;
}

async function openVpPillarDetail(pillarKey, label) {
  const panel = document.getElementById('vida-plena-pillar-detail');
  const titleEl = document.getElementById('vp-detail-title');
  const bodyEl = document.getElementById('vp-detail-body');
  const path = VP_PILLAR_PATHS[pillarKey];
  if (!panel || !titleEl || !bodyEl) return;
  panel.hidden = false;
  titleEl.textContent = label || pillarKey;
  bodyEl.innerHTML = '<p class="task-empty">Cargando...</p>';
  if (!path) {
    bodyEl.innerHTML = '<p class="task-empty">Pilar sin endpoint asociado.</p>';
    return;
  }
  try {
    const data = await api('GET', path);
    bodyEl.innerHTML = renderPillarDetail(label, data && data.summary);
  } catch (e) {
    bodyEl.innerHTML = `<p class="task-empty">Error: ${escapeHtml(e.message || 'desconocido')}</p>`;
  }
  panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

(function wireVpPillarDetailClose() {
  const btn = document.getElementById('vp-detail-close');
  const panel = document.getElementById('vida-plena-pillar-detail');
  if (btn && panel) {
    btn.addEventListener('click', () => { panel.hidden = true; });
  }
})();

// --- Vida Plena: Shopping lists ---
let vpActiveShoppingList = null;

function vpShoppingStatus(msg, kind) {
  const el = document.getElementById('vp-shopping-status');
  if (!el) return;
  el.className = 'vp-status' + (kind ? ' ' + kind : '');
  el.textContent = msg || '';
}

function renderShoppingList(list) {
  const container = document.getElementById('vp-shopping-list');
  if (!container) return;
  if (!list) {
    container.innerHTML = '<p class="task-empty">Sin lista activa.</p>';
    return;
  }
  const items = Array.isArray(list.items) ? list.items : [];
  const header = `<div class="vp-shopping-header"><strong>${escapeHtml(list.name || list.id || 'Lista')}</strong> <span class="pillar-detail">${items.length} items</span></div>`;
  if (items.length === 0) {
    container.innerHTML = header + '<p class="task-empty">Lista vacia.</p>';
    return;
  }
  const rows = items.map((it, idx) => {
    const checked = !!(it.checked || it.completed || it.done);
    const name = it.name || it.label || it.product || 'item';
    const qty = (it.quantity != null) ? `${it.quantity}${it.unit ? ' ' + it.unit : ''}` : '';
    return `<div class="vp-shopping-item${checked ? ' done' : ''}">
      <input type="checkbox" data-vp-shop-name="${escapeHtml(name)}" ${checked ? 'checked' : ''}>
      <span class="vp-item-name">${escapeHtml(name)}</span>
      <span class="pillar-detail">${escapeHtml(qty)}</span>
      <button type="button" class="quick-action-btn" data-vp-shop-del="${idx}">x</button>
    </div>`;
  }).join('');
  container.innerHTML = header + rows;
  container.querySelectorAll('input[type="checkbox"][data-vp-shop-name]').forEach(cb => {
    cb.addEventListener('change', async () => {
      if (!vpActiveShoppingList) return;
      const needle = cb.getAttribute('data-vp-shop-name');
      try {
        await api('POST', `/vida-plena/shopping/lists/${encodeURIComponent(vpActiveShoppingList.id)}/check-by-name`, {
          needle, checked: cb.checked,
        });
        vpShoppingStatus('Item actualizado', 'ok');
        await refreshVpShopping();
      } catch (e) {
        vpShoppingStatus('Error: ' + (e.message || 'falla'), 'error');
      }
    });
  });
  container.querySelectorAll('button[data-vp-shop-del]').forEach(btn => {
    btn.addEventListener('click', async () => {
      if (!vpActiveShoppingList) return;
      const idx = btn.getAttribute('data-vp-shop-del');
      try {
        await api('DELETE', `/vida-plena/shopping/lists/${encodeURIComponent(vpActiveShoppingList.id)}/items/${idx}`);
        vpShoppingStatus('Item eliminado', 'ok');
        await refreshVpShopping();
      } catch (e) {
        vpShoppingStatus('Error: ' + (e.message || 'falla'), 'error');
      }
    });
  });
}

async function refreshVpShopping() {
  try {
    const data = await api('GET', '/vida-plena/shopping/active');
    vpActiveShoppingList = data && data.list ? data.list : null;
    renderShoppingList(vpActiveShoppingList);
  } catch (e) {
    vpShoppingStatus('Error cargando lista activa: ' + (e.message || ''), 'error');
    renderShoppingList(null);
  }
}

(function wireVpShopping() {
  const refreshBtn = document.getElementById('vp-shopping-refresh');
  const genBtn = document.getElementById('vp-shopping-generate');
  const clearBtn = document.getElementById('vp-shopping-clear');
  const addBtn = document.getElementById('vp-shopping-add');
  if (refreshBtn) refreshBtn.addEventListener('click', refreshVpShopping);
  if (genBtn) genBtn.addEventListener('click', async () => {
    const name = prompt('Nombre de la lista semanal:', 'Lista semanal');
    if (!name) return;
    try {
      await api('POST', '/vida-plena/shopping/generate-weekly', { name });
      vpShoppingStatus('Lista generada', 'ok');
      await refreshVpShopping();
    } catch (e) {
      vpShoppingStatus('Error generando: ' + (e.message || ''), 'error');
    }
  });
  if (clearBtn) clearBtn.addEventListener('click', async () => {
    if (!vpActiveShoppingList) { vpShoppingStatus('Sin lista activa', 'error'); return; }
    try {
      const r = await api('POST', `/vida-plena/shopping/lists/${encodeURIComponent(vpActiveShoppingList.id)}/clear-completed`);
      vpShoppingStatus(`Eliminados: ${r && r.removed != null ? r.removed : 0}`, 'ok');
      await refreshVpShopping();
    } catch (e) {
      vpShoppingStatus('Error: ' + (e.message || ''), 'error');
    }
  });
  if (addBtn) addBtn.addEventListener('click', async () => {
    if (!vpActiveShoppingList) { vpShoppingStatus('Sin lista activa', 'error'); return; }
    const nameEl = document.getElementById('vp-shopping-add-name');
    const qtyEl = document.getElementById('vp-shopping-add-qty');
    const unitEl = document.getElementById('vp-shopping-add-unit');
    const name = nameEl && nameEl.value.trim();
    if (!name) { vpShoppingStatus('Nombre requerido', 'error'); return; }
    const item = { name };
    if (qtyEl && qtyEl.value !== '') item.quantity = parseFloat(qtyEl.value);
    if (unitEl && unitEl.value.trim()) item.unit = unitEl.value.trim();
    try {
      await api('POST', `/vida-plena/shopping/lists/${encodeURIComponent(vpActiveShoppingList.id)}/items`, { item });
      vpShoppingStatus('Item agregado', 'ok');
      if (nameEl) nameEl.value = '';
      if (qtyEl) qtyEl.value = '';
      if (unitEl) unitEl.value = '';
      await refreshVpShopping();
    } catch (e) {
      vpShoppingStatus('Error: ' + (e.message || ''), 'error');
    }
  });
})();

// --- Vida Plena: Vault control ---
function vpVaultMsg(msg, kind) {
  const el = document.getElementById('vp-vault-msg');
  if (!el) return;
  el.className = 'vp-status' + (kind ? ' ' + kind : '');
  el.textContent = msg || '';
}

function renderVaultStatus(v) {
  const el = document.getElementById('vp-vault-status');
  if (!el) return;
  if (!v) { el.textContent = 'Estado desconocido'; return; }
  const parts = [];
  if (v.configured != null) parts.push(`configurado: ${v.configured}`);
  if (v.unlocked != null) parts.push(`desbloqueado: ${v.unlocked}`);
  if (v.idle_timeout_secs != null) parts.push(`idle: ${v.idle_timeout_secs}s`);
  if (v.locked_at) parts.push(`locked_at: ${v.locked_at}`);
  el.textContent = parts.length ? parts.join(' | ') : JSON.stringify(v);
}

async function refreshVpVault() {
  try {
    const data = await api('GET', '/vida-plena/vault/status');
    renderVaultStatus(data && data.vault);
  } catch (e) {
    vpVaultMsg('Error cargando estado: ' + (e.message || ''), 'error');
  }
}

(function wireVpVault() {
  const statusBtn = document.getElementById('vp-vault-status-btn');
  const lockBtn = document.getElementById('vp-vault-lock-btn');
  const resetBtn = document.getElementById('vp-vault-reset-btn');
  const setBtn = document.getElementById('vp-vault-set-btn');
  const unlockBtn = document.getElementById('vp-vault-unlock-btn');
  const passEl = document.getElementById('vp-vault-passphrase');
  const idleEl = document.getElementById('vp-vault-idle');
  if (statusBtn) statusBtn.addEventListener('click', refreshVpVault);
  if (lockBtn) lockBtn.addEventListener('click', async () => {
    try { await api('POST', '/vida-plena/vault/lock'); vpVaultMsg('Vault bloqueado', 'ok'); refreshVpVault(); }
    catch (e) { vpVaultMsg('Error: ' + (e.message || ''), 'error'); }
  });
  if (resetBtn) resetBtn.addEventListener('click', async () => {
    if (!confirm('Reset borra la passphrase del vault. Continuar?')) return;
    try { await api('POST', '/vida-plena/vault/reset'); vpVaultMsg('Vault reseteado', 'ok'); refreshVpVault(); }
    catch (e) { vpVaultMsg('Error: ' + (e.message || ''), 'error'); }
  });
  if (setBtn) setBtn.addEventListener('click', async () => {
    const passphrase = passEl && passEl.value;
    if (!passphrase) { vpVaultMsg('Passphrase requerida', 'error'); return; }
    const body = { passphrase };
    if (idleEl && idleEl.value !== '') body.idle_timeout_secs = parseInt(idleEl.value, 10);
    try {
      await api('POST', '/vida-plena/vault/set-passphrase', body);
      vpVaultMsg('Passphrase configurada', 'ok');
      if (passEl) passEl.value = '';
      refreshVpVault();
    } catch (e) { vpVaultMsg('Error: ' + (e.message || ''), 'error'); }
  });
  if (unlockBtn) unlockBtn.addEventListener('click', async () => {
    const passphrase = passEl && passEl.value;
    if (!passphrase) { vpVaultMsg('Passphrase requerida', 'error'); return; }
    try {
      await api('POST', '/vida-plena/vault/unlock', { passphrase });
      vpVaultMsg('Vault desbloqueado', 'ok');
      if (passEl) passEl.value = '';
      refreshVpVault();
    } catch (e) { vpVaultMsg('Error: ' + (e.message || ''), 'error'); }
  });
})();

// --- TTS Voice Selector ---
async function loadTtsVoiceSelector() {
  const selectEl = document.getElementById('voice-select');
  const playBtn = document.getElementById('voice-preview-play');
  const saveBtn = document.getElementById('voice-save');
  const statusEl = document.getElementById('tts-voice-status');
  const banner = document.getElementById('tts-unavailable-banner');
  if (!selectEl) return;

  // Load current preference
  let currentVoice = null;
  try {
    const prefs = await api('GET', '/user/profile');
    currentVoice = prefs && prefs.tts_voice ? prefs.tts_voice : null;
  } catch { /* ignore */ }

  // Load available voices
  try {
    const data = await api('GET', '/tts/voices');
    if (!data || !data.voices || data.voices.length === 0) {
      selectEl.innerHTML = '<option value="">Sin voces disponibles</option>';
      if (playBtn) playBtn.disabled = true;
      return;
    }
    // Group by language
    const byLang = {};
    for (const v of data.voices) {
      const lang = v.language || 'Otras';
      if (!byLang[lang]) byLang[lang] = [];
      byLang[lang].push(v);
    }
    selectEl.innerHTML = '';
    for (const [lang, voices] of Object.entries(byLang)) {
      const group = document.createElement('optgroup');
      group.label = lang;
      for (const v of voices) {
        const opt = document.createElement('option');
        opt.value = v.name;
        opt.textContent = v.name + (v.is_default ? ' (predeterminada)' : '');
        if (v.name === currentVoice || (v.is_default && !currentVoice)) opt.selected = true;
        group.appendChild(opt);
      }
      selectEl.appendChild(group);
    }
    if (playBtn) playBtn.disabled = false;
    if (banner) banner.style.display = 'none';
  } catch (_e) {
    // TTS unavailable — disable controls and show banner
    selectEl.innerHTML = '<option value="">TTS no disponible</option>';
    if (playBtn) playBtn.disabled = true;
    if (banner) banner.style.display = '';
    return;
  }

  // Preview button
  if (playBtn) {
    playBtn.addEventListener('click', async () => {
      const previewInput = document.getElementById('voice-preview-text');
      const text = previewInput ? previewInput.value : 'Hola, soy Axi.';
      const voice = selectEl.value;
      playBtn.disabled = true;
      if (statusEl) statusEl.textContent = 'Sintetizando...';
      try {
        await api('POST', '/sensory/tts/speak', { text, voice_model: voice, playback: true });
        if (statusEl) statusEl.textContent = '';
      } catch {
        if (statusEl) statusEl.textContent = 'Error al reproducir.';
      } finally {
        playBtn.disabled = false;
      }
    });
  }

  // Save button
  if (saveBtn) {
    saveBtn.addEventListener('click', async () => {
      const voice = selectEl.value;
      saveBtn.disabled = true;
      if (statusEl) statusEl.textContent = 'Guardando...';
      try {
        await api('PATCH', '/user/preferences', { key: 'tts_voice', value: voice });
        if (statusEl) {
          statusEl.textContent = 'Guardado.';
          setTimeout(() => { if (statusEl) statusEl.textContent = ''; }, 3000);
        }
      } catch {
        if (statusEl) statusEl.textContent = 'Error al guardar.';
      } finally {
        saveBtn.disabled = false;
      }
    });
  }
}

// --- Boot ---
// --- Modo Privacidad ---
// Toggle global que fuerza al llm_router a usar SOLO providers tier=Local.
// Persistido en ~/.config/lifeos/privacy-mode (override por env LIFEOS_PRIVACY_MODE).
async function loadPrivacyMode() {
  const btn = document.getElementById('privacy-mode-toggle');
  if (!btn) return;
  try {
    const data = await api('GET', '/privacy-mode');
    renderPrivacyMode(Boolean(data?.enabled), data?.source);
  } catch (err) {
    console.warn('privacy-mode load failed:', err);
  }
}

function renderPrivacyMode(enabled, source) {
  const btn = document.getElementById('privacy-mode-toggle');
  if (!btn) return;
  btn.classList.toggle('privacy-on', enabled);
  btn.classList.toggle('privacy-off', !enabled);
  btn.dataset.enabled = enabled ? '1' : '0';
  btn.setAttribute('aria-pressed', enabled ? 'true' : 'false');
  // Only overwrite the tooltip when we actually know the source. When the
  // update comes from an SSE event (where source is unknown), keep whatever
  // tooltip was set by the last load/toggle so the env-override warning
  // sticks across re-renders.
  if (source === 'env') {
    btn.title = 'Modo Privacidad (forzado por env LIFEOS_PRIVACY_MODE — no editable desde aqui)';
  } else if (source === 'file' || source === 'default') {
    btn.title = 'Modo Privacidad: cuando esta activo, el router solo usa modelos locales (sin nube)';
  }
}

async function togglePrivacyMode() {
  const btn = document.getElementById('privacy-mode-toggle');
  if (!btn) return;
  const current = btn.dataset.enabled === '1';
  try {
    const data = await api('POST', '/privacy-mode', { enabled: !current });
    renderPrivacyMode(Boolean(data?.enabled), data?.source);
  } catch (err) {
    console.error('privacy-mode toggle failed:', err);
  }
}

(function wirePrivacyToggle() {
  const btn = document.getElementById('privacy-mode-toggle');
  if (btn) btn.addEventListener('click', togglePrivacyMode);
})();

// ==================== Freelance Module ====================
const freelanceState = {
  clientes: [],
  sesiones: [],
  facturas: [],
  loaded: { clientes: false, sesiones: false, facturas: false, overview: false, tarifas: false },
};

function flFmtMoney(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '—';
  return Number(n).toLocaleString('es-MX', { style: 'currency', currency: 'MXN', minimumFractionDigits: 2 });
}
function flFmtHours(n) {
  if (n === null || n === undefined) return '—';
  return `${Number(n).toFixed(2)}h`;
}
function flFmtDate(s) {
  if (!s) return '—';
  return s.length > 10 ? s.slice(0, 10) : s;
}
function flEsc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
}
function flClienteNombre(id) {
  const c = freelanceState.clientes.find(x => x.cliente_id === id);
  return c ? c.nombre : id;
}

// --- API wrappers ---
async function freelanceListClientes(estado) {
  const q = estado ? `?estado=${encodeURIComponent(estado)}` : '';
  const data = await api('GET', `/freelance/clientes${q}`);
  return data.clientes || [];
}
async function freelanceCreateCliente(body) {
  return api('POST', '/freelance/clientes', body);
}
async function freelanceUpdateCliente(id, body) {
  return api('PATCH', `/freelance/clientes/${encodeURIComponent(id)}`, body);
}
async function freelanceDeleteCliente(id) {
  return api('DELETE', `/freelance/clientes/${encodeURIComponent(id)}`);
}
async function freelanceListSesiones(filters) {
  const params = new URLSearchParams();
  if (filters?.cliente_id) params.set('cliente_id', filters.cliente_id);
  if (filters?.desde) params.set('desde', filters.desde);
  if (filters?.hasta) params.set('hasta', filters.hasta);
  const qs = params.toString();
  const data = await api('GET', `/freelance/sesiones${qs ? '?' + qs : ''}`);
  return data.sesiones || [];
}
async function freelanceCreateSesion(body) {
  return api('POST', '/freelance/sesiones', body);
}
async function freelanceUpdateSesion(id, body) {
  return api('PATCH', `/freelance/sesiones/${encodeURIComponent(id)}`, body);
}
async function freelanceDeleteSesion(id) {
  return api('DELETE', `/freelance/sesiones/${encodeURIComponent(id)}`);
}
async function freelanceListFacturas(filters) {
  const params = new URLSearchParams();
  if (filters?.cliente_id) params.set('cliente_id', filters.cliente_id);
  if (filters?.estado) params.set('estado', filters.estado);
  const qs = params.toString();
  const data = await api('GET', `/freelance/facturas${qs ? '?' + qs : ''}`);
  return data.facturas || [];
}
async function freelanceCreateFactura(body) {
  return api('POST', '/freelance/facturas', body);
}
async function freelancePagarFactura(id, fecha) {
  return api('PATCH', `/freelance/facturas/${encodeURIComponent(id)}`, { fecha_pago: fecha });
}
async function freelanceCancelarFactura(id, razon) {
  return api('PATCH', `/freelance/facturas/${encodeURIComponent(id)}`, { cancelar: true, razon_cancelacion: razon || null });
}
async function freelanceOverview(mes) {
  const q = mes ? `?mes=${encodeURIComponent(mes)}` : '';
  const data = await api('GET', `/freelance/overview${q}`);
  return data.overview || {};
}
async function freelanceTopClientes() {
  const data = await api('GET', '/freelance/top-clientes');
  return data.clientes || [];
}

// --- Cliente helpers ---
async function ensureClientesLoaded(force) {
  if (!force && freelanceState.loaded.clientes) return freelanceState.clientes;
  const estado = document.getElementById('fl-clientes-filter-estado')?.value || '';
  freelanceState.clientes = await freelanceListClientes(estado || null);
  freelanceState.loaded.clientes = true;
  populateClienteSelectors();
  return freelanceState.clientes;
}

function populateClienteSelectors() {
  const selectors = ['fl-sesion-filter-cliente', 'fl-factura-filter-cliente', 'fl-sesion-cliente', 'fl-factura-cliente'];
  selectors.forEach(id => {
    const sel = document.getElementById(id);
    if (!sel) return;
    const includeAll = id.includes('filter');
    const current = sel.value;
    sel.innerHTML = '';
    if (includeAll) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = 'Todos';
      sel.appendChild(opt);
    } else {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = 'Selecciona cliente...';
      sel.appendChild(opt);
    }
    freelanceState.clientes.forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.cliente_id;
      opt.textContent = c.nombre;
      sel.appendChild(opt);
    });
    if (current) sel.value = current;
  });
}

// --- Render: Clientes ---
function renderFreelanceClientes() {
  const container = document.getElementById('fl-clientes-list');
  if (!container) return;
  const list = freelanceState.clientes;
  if (!list.length) {
    container.innerHTML = '<p class="task-empty">Sin clientes. Crea el primero con "+ Nuevo cliente".</p>';
    return;
  }
  const rows = list.map(c => `
    <tr>
      <td><strong>${flEsc(c.nombre)}</strong>${c.contacto_principal ? `<br><small class="fl-muted">${flEsc(c.contacto_principal)}</small>` : ''}</td>
      <td>${flEsc(c.modalidad || 'horas')}</td>
      <td>${c.tarifa_hora != null ? flFmtMoney(c.tarifa_hora) : '—'}</td>
      <td>${c.retainer_mensual != null ? flFmtMoney(c.retainer_mensual) : '—'}</td>
      <td><span class="fl-badge fl-badge-${flEsc(c.estado)}">${flEsc(c.estado)}</span></td>
      <td class="fl-actions">
        <button type="button" class="quick-action-btn fl-btn-sm" data-fl-edit-cliente="${flEsc(c.cliente_id)}">Editar</button>
        <button type="button" class="quick-action-btn quick-action-secondary fl-btn-sm" data-fl-del-cliente="${flEsc(c.cliente_id)}">Terminar</button>
      </td>
    </tr>
  `).join('');
  container.innerHTML = `
    <table class="freelance-table">
      <thead><tr><th>Nombre</th><th>Modalidad</th><th>Tarifa/h</th><th>Retainer</th><th>Estado</th><th>Acciones</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
  container.querySelectorAll('[data-fl-edit-cliente]').forEach(btn => {
    btn.addEventListener('click', () => openClienteDialog(btn.dataset.flEditCliente));
  });
  container.querySelectorAll('[data-fl-del-cliente]').forEach(btn => {
    btn.addEventListener('click', async () => {
      if (!confirm('Marcar cliente como terminado?')) return;
      try {
        await freelanceDeleteCliente(btn.dataset.flDelCliente);
        await ensureClientesLoaded(true);
        renderFreelanceClientes();
      } catch (e) { alert('Error: ' + e.message); }
    });
  });
}

function openClienteDialog(id) {
  const dlg = document.getElementById('fl-cliente-dialog');
  if (!dlg) return;
  document.getElementById('fl-cliente-form-error').textContent = '';
  const editRow = document.getElementById('fl-cliente-estado-row');
  if (id) {
    const c = freelanceState.clientes.find(x => x.cliente_id === id);
    if (!c) return;
    document.getElementById('fl-cliente-form-title').textContent = 'Editar cliente';
    document.getElementById('fl-cliente-id').value = c.cliente_id;
    document.getElementById('fl-cliente-nombre').value = c.nombre || '';
    document.getElementById('fl-cliente-modalidad').value = c.modalidad || 'horas';
    document.getElementById('fl-cliente-tarifa').value = c.tarifa_hora ?? '';
    document.getElementById('fl-cliente-retainer').value = c.retainer_mensual ?? '';
    document.getElementById('fl-cliente-horas-comp').value = c.horas_comprometidas_mes ?? '';
    document.getElementById('fl-cliente-fecha-inicio').value = flFmtDate(c.fecha_inicio);
    document.getElementById('fl-cliente-contacto').value = c.contacto_principal || '';
    document.getElementById('fl-cliente-email').value = c.contacto_email || '';
    document.getElementById('fl-cliente-telefono').value = c.contacto_telefono || '';
    document.getElementById('fl-cliente-rfc').value = c.rfc || '';
    document.getElementById('fl-cliente-notas').value = c.notas || '';
    document.getElementById('fl-cliente-estado').value = c.estado || 'activo';
    if (editRow) editRow.style.display = '';
  } else {
    document.getElementById('fl-cliente-form-title').textContent = 'Nuevo cliente';
    document.getElementById('fl-cliente-id').value = '';
    document.getElementById('fl-cliente-form').reset();
    if (editRow) editRow.style.display = 'none';
  }
  dlg.showModal();
}

async function submitClienteForm(ev) {
  ev.preventDefault();
  const id = document.getElementById('fl-cliente-id').value;
  const errEl = document.getElementById('fl-cliente-form-error');
  errEl.textContent = '';
  const body = {
    nombre: document.getElementById('fl-cliente-nombre').value.trim(),
    modalidad: document.getElementById('fl-cliente-modalidad').value || null,
    tarifa_hora: parseFloat(document.getElementById('fl-cliente-tarifa').value) || null,
    retainer_mensual: parseFloat(document.getElementById('fl-cliente-retainer').value) || null,
    horas_comprometidas_mes: parseInt(document.getElementById('fl-cliente-horas-comp').value) || null,
    fecha_inicio: document.getElementById('fl-cliente-fecha-inicio').value || null,
    contacto_principal: document.getElementById('fl-cliente-contacto').value || null,
    contacto_email: document.getElementById('fl-cliente-email').value || null,
    contacto_telefono: document.getElementById('fl-cliente-telefono').value || null,
    rfc: document.getElementById('fl-cliente-rfc').value || null,
    notas: document.getElementById('fl-cliente-notas').value || null,
  };
  if (id) body.estado = document.getElementById('fl-cliente-estado').value;
  if (!body.nombre) { errEl.textContent = 'Nombre requerido'; return; }
  try {
    if (id) await freelanceUpdateCliente(id, body);
    else await freelanceCreateCliente(body);
    document.getElementById('fl-cliente-dialog').close();
    await ensureClientesLoaded(true);
    renderFreelanceClientes();
    renderFreelanceTarifas();
  } catch (e) { errEl.textContent = e.message; }
}

// --- Render: Sesiones ---
function renderFreelanceSesiones() {
  const container = document.getElementById('fl-sesiones-list');
  if (!container) return;
  const list = freelanceState.sesiones;
  if (!list.length) {
    container.innerHTML = '<p class="task-empty">Sin sesiones registradas.</p>';
    return;
  }
  const rows = list.map(s => `
    <tr>
      <td>${flFmtDate(s.fecha)}</td>
      <td>${flEsc(flClienteNombre(s.cliente_id))}</td>
      <td>${flFmtHours(s.horas)}</td>
      <td>${flEsc(s.descripcion || '')}</td>
      <td>${s.facturable ? '<span class="val-ok">Si</span>' : '<span class="val-error">No</span>'}</td>
      <td>${s.factura_id ? '<span class="fl-badge fl-badge-pagada">Facturada</span>' : '<span class="fl-badge">Pendiente</span>'}</td>
      <td class="fl-actions">
        <button type="button" class="quick-action-btn quick-action-secondary fl-btn-sm" data-fl-del-sesion="${flEsc(s.sesion_id)}">Borrar</button>
      </td>
    </tr>`).join('');
  container.innerHTML = `
    <table class="freelance-table">
      <thead><tr><th>Fecha</th><th>Cliente</th><th>Horas</th><th>Descripcion</th><th>Facturable</th><th>Estado</th><th>Acciones</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
  container.querySelectorAll('[data-fl-del-sesion]').forEach(btn => {
    btn.addEventListener('click', async () => {
      if (!confirm('Borrar sesion?')) return;
      try {
        await freelanceDeleteSesion(btn.dataset.flDelSesion);
        await refreshSesiones();
      } catch (e) { alert('Error: ' + e.message); }
    });
  });
}

async function refreshSesiones() {
  const filters = {
    cliente_id: document.getElementById('fl-sesion-filter-cliente')?.value || null,
    desde: document.getElementById('fl-sesion-filter-desde')?.value || null,
    hasta: document.getElementById('fl-sesion-filter-hasta')?.value || null,
  };
  freelanceState.sesiones = await freelanceListSesiones(filters);
  renderFreelanceSesiones();
}

function openSesionDialog() {
  const dlg = document.getElementById('fl-sesion-dialog');
  if (!dlg) return;
  document.getElementById('fl-sesion-form-error').textContent = '';
  document.getElementById('fl-sesion-form').reset();
  document.getElementById('fl-sesion-facturable').checked = true;
  document.getElementById('fl-sesion-fecha').value = new Date().toISOString().slice(0, 10);
  populateClienteSelectors();
  dlg.showModal();
}

async function submitSesionForm(ev) {
  ev.preventDefault();
  const errEl = document.getElementById('fl-sesion-form-error');
  errEl.textContent = '';
  const cliente_id = document.getElementById('fl-sesion-cliente').value;
  const horas = parseFloat(document.getElementById('fl-sesion-horas').value);
  if (!cliente_id) { errEl.textContent = 'Cliente requerido'; return; }
  if (!horas || horas <= 0) { errEl.textContent = 'Horas debe ser > 0'; return; }
  const body = {
    cliente_id,
    horas,
    fecha: document.getElementById('fl-sesion-fecha').value || null,
    hora_inicio: document.getElementById('fl-sesion-hora-inicio').value || null,
    hora_fin: document.getElementById('fl-sesion-hora-fin').value || null,
    descripcion: document.getElementById('fl-sesion-descripcion').value || null,
    facturable: document.getElementById('fl-sesion-facturable').checked,
  };
  try {
    await freelanceCreateSesion(body);
    document.getElementById('fl-sesion-dialog').close();
    await refreshSesiones();
  } catch (e) { errEl.textContent = e.message; }
}

// --- Render: Facturas ---
function renderFreelanceFacturas() {
  const container = document.getElementById('fl-facturas-list');
  if (!container) return;
  const list = freelanceState.facturas;
  if (!list.length) {
    container.innerHTML = '<p class="task-empty">Sin facturas.</p>';
    return;
  }
  const rows = list.map(f => `
    <tr>
      <td>${flEsc(f.numero_externo || f.factura_id.slice(0, 10))}</td>
      <td>${flEsc(flClienteNombre(f.cliente_id))}</td>
      <td>${flFmtDate(f.fecha_emision)}</td>
      <td>${flFmtDate(f.fecha_vencimiento)}</td>
      <td>${flFmtMoney(f.monto_total)}</td>
      <td><span class="fl-badge fl-badge-${flEsc(f.estado)}">${flEsc(f.estado)}</span></td>
      <td class="fl-actions">
        ${f.estado === 'emitida' || f.estado === 'vencida' ? `<button type="button" class="quick-action-btn fl-btn-sm" data-fl-pay="${flEsc(f.factura_id)}">Marcar pagada</button>` : ''}
        ${f.estado !== 'cancelada' && f.estado !== 'pagada' ? `<button type="button" class="quick-action-btn quick-action-secondary fl-btn-sm" data-fl-cancel="${flEsc(f.factura_id)}">Cancelar</button>` : ''}
      </td>
    </tr>`).join('');
  container.innerHTML = `
    <table class="freelance-table">
      <thead><tr><th>Numero</th><th>Cliente</th><th>Emision</th><th>Vencimiento</th><th>Total</th><th>Estado</th><th>Acciones</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
  container.querySelectorAll('[data-fl-pay]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const fecha = prompt('Fecha de pago (YYYY-MM-DD):', new Date().toISOString().slice(0, 10));
      if (!fecha) return;
      try {
        await freelancePagarFactura(btn.dataset.flPay, fecha);
        await refreshFacturas();
      } catch (e) { alert('Error: ' + e.message); }
    });
  });
  container.querySelectorAll('[data-fl-cancel]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const razon = prompt('Razon de cancelacion (opcional):', '');
      if (razon === null) return;
      try {
        await freelanceCancelarFactura(btn.dataset.flCancel, razon);
        await refreshFacturas();
      } catch (e) { alert('Error: ' + e.message); }
    });
  });
}

async function refreshFacturas() {
  const filters = {
    cliente_id: document.getElementById('fl-factura-filter-cliente')?.value || null,
    estado: document.getElementById('fl-factura-filter-estado')?.value || null,
  };
  freelanceState.facturas = await freelanceListFacturas(filters);
  renderFreelanceFacturas();
}

function openFacturaDialog() {
  const dlg = document.getElementById('fl-factura-dialog');
  if (!dlg) return;
  document.getElementById('fl-factura-form-error').textContent = '';
  document.getElementById('fl-factura-form').reset();
  document.getElementById('fl-factura-fecha-emision').value = new Date().toISOString().slice(0, 10);
  populateClienteSelectors();
  dlg.showModal();
}

async function submitFacturaForm(ev) {
  ev.preventDefault();
  const errEl = document.getElementById('fl-factura-form-error');
  errEl.textContent = '';
  const cliente_id = document.getElementById('fl-factura-cliente').value;
  const monto_subtotal = parseFloat(document.getElementById('fl-factura-subtotal').value);
  if (!cliente_id) { errEl.textContent = 'Cliente requerido'; return; }
  if (!monto_subtotal || monto_subtotal <= 0) { errEl.textContent = 'Subtotal debe ser > 0'; return; }
  const body = {
    cliente_id,
    monto_subtotal,
    monto_iva: parseFloat(document.getElementById('fl-factura-iva').value) || null,
    fecha_emision: document.getElementById('fl-factura-fecha-emision').value || null,
    fecha_vencimiento: document.getElementById('fl-factura-fecha-vencimiento').value || null,
    numero_externo: document.getElementById('fl-factura-numero').value || null,
    concepto: document.getElementById('fl-factura-concepto').value || null,
  };
  try {
    await freelanceCreateFactura(body);
    document.getElementById('fl-factura-dialog').close();
    await refreshFacturas();
  } catch (e) { errEl.textContent = e.message; }
}

// --- Render: Resumen ---
async function refreshFreelanceOverview() {
  try {
    const mes = document.getElementById('fl-overview-mes')?.value || null;
    const ov = await freelanceOverview(mes);
    const set = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val; };
    set('fl-stat-horas', flFmtHours(ov.horas_trabajadas ?? 0));
    set('fl-stat-horas-comp', `${ov.horas_comprometidas ?? 0}h`);
    set('fl-stat-clientes', String(ov.clientes_activos ?? 0));
    set('fl-stat-cxc', flFmtMoney(ov.cuentas_por_cobrar ?? 0));
    set('fl-stat-emitido', flFmtMoney(ov.facturacion_emitida ?? 0));
    set('fl-stat-pagado', flFmtMoney(ov.facturacion_pagada ?? 0));

    // Alertas
    const alertasEl = document.getElementById('fl-overview-alertas');
    if (alertasEl) {
      const alertas = ov.alertas || [];
      if (!alertas.length) alertasEl.innerHTML = '';
      else {
        alertasEl.innerHTML = `<h3 style="margin:8px 0;">Alertas</h3>` +
          alertas.map(a => `<div class="fl-badge fl-badge-vencida" style="display:block;margin:4px 0;padding:8px;">${flEsc(typeof a === 'string' ? a : (a.mensaje || JSON.stringify(a)))}</div>`).join('');
      }
    }

    // Top clientes list
    const topList = document.getElementById('fl-top-clientes-list');
    if (topList) {
      try {
        const top = await freelanceTopClientes();
        if (!top.length) topList.innerHTML = '<p class="task-empty">Sin facturacion en el periodo</p>';
        else {
          const rows = top.slice(0, 10).map((c, i) => `
            <tr><td>${i + 1}</td><td>${flEsc(c.nombre || c.cliente_nombre || c.cliente_id)}</td><td>${flFmtMoney(c.total ?? c.facturado ?? c.monto)}</td></tr>`).join('');
          topList.innerHTML = `<table class="freelance-table"><thead><tr><th>#</th><th>Cliente</th><th>Total</th></tr></thead><tbody>${rows}</tbody></table>`;
        }
      } catch (e) {
        topList.innerHTML = `<p class="task-empty">Error: ${flEsc(e.message)}</p>`;
      }
    }
  } catch (e) {
    console.warn('freelance overview failed', e);
  }
}

// --- Render: Tarifas ---
function renderFreelanceTarifas() {
  const container = document.getElementById('fl-tarifas-list');
  if (!container) return;
  const list = freelanceState.clientes;
  if (!list.length) {
    container.innerHTML = '<p class="task-empty">Sin clientes para mostrar tarifas.</p>';
    return;
  }
  const rows = list.map(c => `
    <tr>
      <td><strong>${flEsc(c.nombre)}</strong></td>
      <td>${flEsc(c.modalidad || 'horas')}</td>
      <td>${c.tarifa_hora != null ? flFmtMoney(c.tarifa_hora) : '—'}</td>
      <td>${c.retainer_mensual != null ? flFmtMoney(c.retainer_mensual) : '—'}</td>
      <td class="fl-actions">
        <button type="button" class="quick-action-btn fl-btn-sm" data-fl-tarifa="${flEsc(c.cliente_id)}">Cambiar tarifa</button>
      </td>
    </tr>`).join('');
  container.innerHTML = `
    <table class="freelance-table">
      <thead><tr><th>Cliente</th><th>Modalidad</th><th>Tarifa/h</th><th>Retainer</th><th>Acciones</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
  container.querySelectorAll('[data-fl-tarifa]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.dataset.flTarifa;
      const c = freelanceState.clientes.find(x => x.cliente_id === id);
      const current = c?.tarifa_hora ?? '';
      const next = prompt(`Nueva tarifa por hora (MXN) para ${c?.nombre}:`, String(current));
      if (next === null) return;
      const val = parseFloat(next);
      if (!val || val <= 0) { alert('Tarifa invalida'); return; }
      try {
        await freelanceUpdateCliente(id, { tarifa_hora: val });
        await ensureClientesLoaded(true);
        renderFreelanceTarifas();
        renderFreelanceClientes();
      } catch (e) { alert('Error: ' + e.message); }
    });
  });
}

// --- Init ---
function initFreelance() {
  // Cliente form
  document.getElementById('fl-cliente-new-btn')?.addEventListener('click', () => openClienteDialog(null));
  document.getElementById('fl-cliente-form')?.addEventListener('submit', submitClienteForm);
  document.getElementById('fl-cliente-cancel')?.addEventListener('click', () => document.getElementById('fl-cliente-dialog').close());
  document.getElementById('fl-clientes-refresh')?.addEventListener('click', async () => {
    await ensureClientesLoaded(true); renderFreelanceClientes();
  });
  document.getElementById('fl-clientes-filter-estado')?.addEventListener('change', async () => {
    await ensureClientesLoaded(true); renderFreelanceClientes();
  });

  // Sesion form
  document.getElementById('fl-sesion-new-btn')?.addEventListener('click', async () => {
    await ensureClientesLoaded(); openSesionDialog();
  });
  document.getElementById('fl-sesion-form')?.addEventListener('submit', submitSesionForm);
  document.getElementById('fl-sesion-cancel')?.addEventListener('click', () => document.getElementById('fl-sesion-dialog').close());
  document.getElementById('fl-sesiones-refresh')?.addEventListener('click', refreshSesiones);

  // Factura form
  document.getElementById('fl-factura-new-btn')?.addEventListener('click', async () => {
    await ensureClientesLoaded(); openFacturaDialog();
  });
  document.getElementById('fl-factura-form')?.addEventListener('submit', submitFacturaForm);
  document.getElementById('fl-factura-cancel')?.addEventListener('click', () => document.getElementById('fl-factura-dialog').close());
  document.getElementById('fl-facturas-refresh')?.addEventListener('click', refreshFacturas);

  // Overview
  const mesInput = document.getElementById('fl-overview-mes');
  if (mesInput) {
    const now = new Date();
    mesInput.value = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  }
  document.getElementById('fl-overview-refresh')?.addEventListener('click', refreshFreelanceOverview);

  // Lazy-load when freelance section becomes active
  document.querySelectorAll('.sidebar-submenu-item[data-parent="freelance"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const target = btn.dataset.subsectionTarget;
      try {
        if (target === 'fl-clientes') {
          await ensureClientesLoaded(); renderFreelanceClientes();
        } else if (target === 'fl-sesiones') {
          await ensureClientesLoaded(); await refreshSesiones();
        } else if (target === 'fl-facturas') {
          await ensureClientesLoaded(); await refreshFacturas();
        } else if (target === 'fl-tarifas') {
          await ensureClientesLoaded(true); renderFreelanceTarifas();
        } else if (target === 'fl-resumen') {
          await refreshFreelanceOverview();
        }
      } catch (e) { console.warn('freelance load', target, e); }
    });
  });
}

(async () => {
  initTabs();
  await ensureBootstrapToken();
  await fetchInitialState();
  loadPrivacyMode();
  connectSSE();
  connectWebSocket();
  checkSafeMode();
  refreshDoctor();
  refreshConversations();
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
  refreshWorkers();
  refreshSystemHealth();
  refreshVidaPlena();
  refreshVpShopping();
  refreshVpVault();
  loadMeetings();
  loadCalendar();
  loadTtsVoiceSelector();
  initFreelance();
  runWelcomeSequence().catch(err => console.warn('welcome sequence failed:', err));
})();
