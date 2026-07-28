// cartesia-backend.mjs - Cartesia "sonic-2" TTS backend for POST /tts (a real online voice for the login-free demo).
// SAME ttsBackend(text, opts) -> { audio: Buffer, format } contract as tts.mjs's createElevenLabsBackend /
// createPocketTTSBackend, so it drops straight into createGateway({ ttsBackend }). The Cartesia API key lives ONLY
// here (server-side): the phone sends text and receives WAV bytes, never the key. Zero external deps (Node 22 global
// fetch + AbortController). A hard timeout aborts a hung/slow Cartesia call so /tts fails closed, never stalls.
//
// Cartesia TTS bytes API:
//   POST https://api.cartesia.ai/tts/bytes
//   headers: 'Cartesia-Version': '2024-11-13', 'X-API-Key': <key>, 'Content-Type': 'application/json'
//   body:    { model_id, transcript, voice:{mode:'id',id}, output_format:{container,encoding,sample_rate}, language }
//   2xx -> raw audio bytes (arrayBuffer). Non-2xx / empty -> throw (handleTts maps a throw to 502, fail-closed).

/**
 * @param {{ apiKey:string, voiceId:string, fetch?:Function, timeoutMs?:number, baseUrl?:string,
 *           container?:string, encoding?:string, sampleRate?:number, format?:string }} cfg
 *   - container/encoding/sampleRate/format: output_format overrides (default WAV pcm_s16le 24000 -> format 'wav').
 * @returns ttsBackend(text, opts) -> { audio: Buffer, format }
 */
export function createCartesiaBackend(cfg = {}) {
  const {
    apiKey,
    voiceId,
    fetch = globalThis.fetch,
    timeoutMs = 10000,
    baseUrl = 'https://api.cartesia.ai',
    container = 'wav',
    encoding = 'pcm_s16le',
    sampleRate = 24000,
    format = 'wav',
  } = cfg;
  if (!apiKey) throw new Error('createCartesiaBackend: apiKey required (server-side only)');
  if (!voiceId) throw new Error('createCartesiaBackend: voiceId required');
  if (typeof fetch !== 'function') throw new Error('createCartesiaBackend: no fetch implementation available');
  const timeout = Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 10000;
  const url = String(baseUrl).replace(/\/+$/, '') + '/tts/bytes';

  return async function ttsBackend(text, opts = {}) {
    const t = String(text ?? '');
    if (!t) throw new Error('text required');
    const id = (opts && opts.voiceId) || voiceId; // a caller voiceId may override the configured default; else the default
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeout); // hard cap covers BOTH the request and the body read
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Cartesia-Version': '2024-11-13',
          'X-API-Key': apiKey,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model_id: 'sonic-2',
          transcript: t,
          voice: { mode: 'id', id },
          output_format: { container, encoding, sample_rate: sampleRate },
          language: 'en',
        }),
        signal: ac.signal,
      });
      if (!res || !res.ok) {
        let detail = '';
        try { detail = (await res.text()).slice(0, 500); } catch { /* ignore body read error */ }
        throw new Error('cartesia error ' + (res && res.status) + (detail ? ': ' + detail : ''));
      }
      const audio = Buffer.from(await res.arrayBuffer());
      if (audio.length === 0) throw new Error('cartesia returned empty audio');
      return { audio, format };
    } finally {
      clearTimeout(timer);
    }
  };
}
