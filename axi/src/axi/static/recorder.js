// Segmented streaming voice recorder — shared by the chat and the "Desarrollo"
// section (DRY: one implementation, two pages). Records in ~20s segments,
// transcribes each, and reports the text via onText so the page can append it
// to its input live. Unbounded duration (no single-shot 20MB / 30s ceiling) and
// resilient — one failed segment never costs the whole dictation.
//
// Usage:
//   const rec = createSegmentedRecorder({
//     onText:  (text) => { /* append to your input */ },
//     onError: (msg)  => { /* show error */ },
//     onState: ({recording, transcribing}) => { /* bind button state */ },
//   });
//   rec.start();  // on mousedown/touchstart
//   rec.stop();   // on mouseup/touchend/leave
window.createSegmentedRecorder = function (opts) {
  opts = opts || {};
  const SEGMENT_MS = opts.segmentMs || 20000;
  const TRANSCRIBE_URL = opts.transcribeUrl || '/api/chat/transcribe';
  const onText = opts.onText || function () {};
  const onError = opts.onError || function () {};
  const onState = opts.onState || function () {};

  let stream = null;
  let mediaRecorder = null;
  let mime = 'audio/webm';
  let segTimer = null;
  let segChain = Promise.resolve();
  let recording = false;
  let transcribing = false;

  function emit() { onState({ recording: recording, transcribing: transcribing }); }
  function setTranscribing(v) { transcribing = v; emit(); }

  function blobToB64(blob) {
    return new Promise(function (resolve, reject) {
      const reader = new FileReader();
      reader.onloadend = function () {
        const s = String(reader.result || '');
        const i = s.indexOf(',');
        resolve(i >= 0 ? s.slice(i + 1) : s);
      };
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  }

  function releaseStream() {
    try { if (stream) stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
    stream = null;
  }

  async function transcribeBlob(blob) {
    setTranscribing(true);
    try {
      const b64 = await blobToB64(blob);
      const r = await fetch(TRANSCRIBE_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ audio_b64: b64, ext: 'webm' }),
      });
      if (!r.ok) {
        const detail = await r.text();
        throw new Error('HTTP ' + r.status + ': ' + detail);
      }
      const data = await r.json();
      const text = (data.text || '').trim();
      if (text) onText(text);
      // Empty segment = a silent pause — skipped silently.
    } catch (e) {
      onError('Un tramo no se transcribió (' + e.message + ') — seguí, el resto se conserva.');
    }
  }

  function flushSegment(chunks) {
    const stillRecording = recording;
    // Restart capture immediately (stream stays hot) so the gap between
    // segments is just the MediaRecorder spin-up; then transcribe in background.
    if (stillRecording) startSegment(); else releaseStream();
    if (chunks && chunks.length) {
      const blob = new Blob(chunks, { type: mime });
      segChain = segChain.then(function () { return transcribeBlob(blob); });
    }
    if (!stillRecording) segChain.finally(function () { setTranscribing(false); });
  }

  function startSegment() {
    if (!stream) return;
    let rec;
    try {
      rec = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream);
    } catch (e) {
      onError('No pude iniciar MediaRecorder: ' + e.message);
      releaseStream();
      recording = false;
      emit();
      return;
    }
    const chunks = [];
    rec.ondataavailable = function (ev) { if (ev.data && ev.data.size > 0) chunks.push(ev.data); };
    rec.onstop = function () { flushSegment(chunks); };
    mediaRecorder = rec;
    rec.start();
    segTimer = setTimeout(function () {
      if (recording) { try { rec.stop(); } catch (e) {} }
    }, SEGMENT_MS);
  }

  async function start() {
    if (recording || transcribing) return;
    if (!navigator.mediaDevices || !window.MediaRecorder) {
      onError('Este navegador no soporta grabación de audio.');
      return;
    }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      onError('No pude acceder al micrófono: ' + e.message);
      return;
    }
    let m = 'audio/webm;codecs=opus';
    if (!MediaRecorder.isTypeSupported(m)) {
      m = 'audio/webm';
      if (!MediaRecorder.isTypeSupported(m)) m = '';
    }
    mime = m || 'audio/webm';
    segChain = Promise.resolve();
    recording = true;
    emit();
    startSegment();
  }

  function stop() {
    if (!recording) return;
    recording = false;
    emit();
    if (segTimer) { clearTimeout(segTimer); segTimer = null; }
    try { if (mediaRecorder) mediaRecorder.stop(); } catch (e) {}
  }

  return {
    start: start,
    stop: stop,
    isRecording: function () { return recording; },
    isTranscribing: function () { return transcribing; },
  };
};
