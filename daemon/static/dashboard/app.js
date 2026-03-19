// LifeOS Dashboard — API client, SSE listener, diagnostics, UI logic
'use strict';

// --- Token management ---
const params = new URLSearchParams(location.search);
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
function updateOrb(state, aura) {
  const key = (state || 'offline').toLowerCase();
  orb.className = 'orb ' + (AURA_MAP[key] || 'aura-gray');
  stateLabel.textContent = STATE_LABELS[key] || key;
}

function updateOverlayDetails(overlay) {
  if (!overlay) return;
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
}

function updateSensoryToggles(runtime) {
  $('#toggle-audio').checked = runtime.audio_enabled;
  $('#toggle-screen').checked = runtime.screen_enabled;
  $('#toggle-camera').checked = runtime.camera_enabled;
  $('#audio-status').textContent = runtime.audio_enabled ? 'Activo' : 'Inactivo';
  $('#screen-status').textContent = runtime.screen_enabled ? 'Activo' : 'Inactivo';
  $('#camera-status').textContent = runtime.camera_enabled ? 'Activo' : 'Inactivo';
}

function updateAlwaysOn(ao) {
  $('#toggle-always-on').checked = ao.enabled;
  $('#always-on-status').textContent = ao.enabled ? 'Activo' : 'Inactivo';
  if (ao.wake_word) $('#wake-word-input').value = ao.wake_word;
}

function updateContext(ctx) {
  $('#current-app').textContent = ctx.current_application || '—';
  $('#current-window').textContent = ctx.current_window || '—';
}

function updatePresence(p) {
  if (!p) return;
  $('#presence-status').textContent = p.present ? 'Presente' : 'Ausente';
  const details = [];
  if (p.user_state) details.push(p.user_state);
  if (p.people_count != null) details.push(p.people_count + ' persona(s)');
  $('#presence-detail').textContent = details.join(' · ') || '—';
}

function updateVoice(voice) {
  if (!voice) return;
  $('#last-transcript').textContent = voice.last_transcript || '—';
  $('#last-response').textContent = voice.last_response
    ? voice.last_response.substring(0, 120) + (voice.last_response.length > 120 ? '...' : '')
    : '—';
}

function updateMeeting(m) {
  if (!m) return;
  $('#meeting-status').textContent = m.active ? 'En reunion' : 'Sin reunion';
  $('#meeting-app').textContent = m.conferencing_app || '';
}

// --- Activity feed ---
function addFeedItem(icon, text) {
  const now = new Date();
  const time = now.toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const item = document.createElement('div');
  item.className = 'feed-item';
  item.innerHTML = `<span class="feed-time">${time}</span><span class="feed-icon">${icon}</span><span class="feed-text">${text}</span>`;
  activityFeed.prepend(item);
  feedCount++;
  feedCountEl.textContent = feedCount;
  while (activityFeed.children.length > MAX_FEED) {
    activityFeed.removeChild(activityFeed.lastChild);
  }
}

// --- SSE connection ---
function connectSSE() {
  const url = `${API}/events/stream?token=${encodeURIComponent(token)}`;
  const sse = new EventSource(url);

  sse.onopen = () => {
    connectionBadge.textContent = 'Conectado';
    connectionBadge.className = 'badge badge-online';
  };

  sse.onerror = () => {
    connectionBadge.textContent = 'Desconectado';
    connectionBadge.className = 'badge badge-offline';
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
      updateOrb(event.data.state, event.data.aura);
      if (event.data.reason) stateReason.textContent = event.data.reason;
      addFeedItem('&#9679;', `Axi → ${event.data.state}`);
      break;
    case 'sensor_changed':
      $('#toggle-audio').checked = event.data.mic;
      $('#toggle-screen').checked = event.data.screen;
      $('#toggle-camera').checked = event.data.camera;
      $('#audio-status').textContent = event.data.mic ? 'Activo' : 'Inactivo';
      $('#screen-status').textContent = event.data.screen ? 'Activo' : 'Inactivo';
      $('#camera-status').textContent = event.data.camera ? 'Activo' : 'Inactivo';
      if (event.data.kill_switch) addFeedItem('&#9888;', 'Kill switch activado');
      break;
    case 'feedback_update':
      if (event.data.stage) {
        feedbackBar.classList.remove('hidden');
        feedbackStage.textContent = event.data.stage;
        feedbackTps.textContent = event.data.tokens_per_second
          ? `${event.data.tokens_per_second.toFixed(1)} tok/s` : '';
      } else {
        feedbackBar.classList.add('hidden');
      }
      break;
    case 'window_changed':
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
      if (event.data.transcript) {
        $('#last-transcript').textContent = event.data.transcript;
        addFeedItem('&#128172;', event.data.transcript);
      }
      if (event.data.response) {
        const short = event.data.response.substring(0, 80);
        $('#last-response').textContent = short;
      }
      break;
    case 'screen_capture':
      addFeedItem('&#128247;', event.data.summary || 'Captura de pantalla');
      break;
    case 'meeting_state_changed':
      $('#meeting-status').textContent = event.data.active ? 'En reunion' : 'Sin reunion';
      $('#meeting-app').textContent = event.data.app || '';
      addFeedItem('&#128222;', event.data.active
        ? `Reunion detectada (${event.data.app || '?'})` : 'Reunion finalizada');
      break;
    case 'presence_update':
      $('#presence-status').textContent = event.data.present ? 'Presente' : 'Ausente';
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
        const labels = { audio: '&#9654; Probar Oido', screen: '&#128247; Capturar Pantalla', camera: '&#128247; Capturar Camara' };
        btn.innerHTML = labels[sensor] || 'Probar';
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

async function toggleSensory(field, value) {
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
  } catch (err) {
    addFeedItem('&#10060;', `Error toggle ${field}: ${err.message}`);
  }
}

$('#toggle-audio').addEventListener('change', (e) => toggleSensory('audio_enabled', e.target.checked));
$('#toggle-screen').addEventListener('change', (e) => toggleSensory('screen_enabled', e.target.checked));
$('#toggle-camera').addEventListener('change', (e) => toggleSensory('camera_enabled', e.target.checked));

$('#toggle-always-on').addEventListener('change', async (e) => {
  try { await api('POST', '/runtime/always-on', { enabled: e.target.checked }); }
  catch (err) { addFeedItem('&#10060;', `Error toggle always-on: ${err.message}`); }
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

$('#wake-word-save').addEventListener('click', async () => {
  const word = $('#wake-word-input').value.trim();
  if (word) await api('POST', '/runtime/always-on', { enabled: true, wake_word: word });
});

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

    if (overlay.axi_state) updateOrb(overlay.axi_state);
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
    }).catch(() => {});

    connectionBadge.textContent = 'Conectado';
    connectionBadge.className = 'badge badge-online';
  } catch (err) {
    console.error('Failed to fetch initial state:', err);
    addFeedItem('&#9888;', 'Error al cargar estado inicial: ' + err.message);
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

    if (overlay?.axi_state) updateOrb(overlay.axi_state);
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
    }
  } catch (e) {
    console.warn('periodic refresh failed:', e);
  }
}

setInterval(refreshFullState, 3000);

// --- Boot ---
(async () => {
  await ensureBootstrapToken();
  await fetchInitialState();
  connectSSE();
})();
