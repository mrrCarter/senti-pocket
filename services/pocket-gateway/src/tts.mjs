// tts.mjs — ElevenLabs TTS backend for POST /tts (Echo P1: concrete backend). The provider API key lives ONLY
// here (server-side); the phone sends text + a voiceId and receives raw PCM — never the key. `fetch` is injectable
// (built-in on Node ≥18) so this is hermetically testable with no network.

/** Map a coarse tone hint to ElevenLabs voice_settings. */
function toneToSettings(tone) {
  switch (String(tone || '').toLowerCase()) {
    case 'urgent': return { stability: 0.3, similarity_boost: 0.75 };
    case 'calm': return { stability: 0.85, similarity_boost: 0.6 };
    default: return { stability: 0.5, similarity_boost: 0.7 };
  }
}

/**
 * @param {{ apiKey:string, fetch?:Function, baseUrl?:string, defaultVoiceId?:string }} cfg
 * @returns ttsBackend(text, {voiceId,modelId,outputFormat,tone}) -> { audio: Buffer, format }
 */
export function createElevenLabsBackend(cfg = {}) {
  const { apiKey, baseUrl = 'https://api.elevenlabs.io', defaultVoiceId } = cfg;
  const doFetch = cfg.fetch || globalThis.fetch;
  const timeoutMs = Number.isFinite(cfg.timeoutMs) && cfg.timeoutMs > 0 ? cfg.timeoutMs : 10_000; // hard cap: a hung/slow ElevenLabs call fails closed, never hangs the ring/brief (parity with createPocketTTSBackend)
  if (!apiKey) throw new Error('ElevenLabs apiKey required (server-side only)');
  if (typeof doFetch !== 'function') throw new Error('no fetch implementation available');

  // Descriptive labels for raw PCM (a PCM consumer needs encoding+rate to decode); mp3/other are self-describing.
  const PCM_LABELS = { pcm_16000: 'pcm_s16le_16000', pcm_22050: 'pcm_s16le_22050', pcm_24000: 'pcm_s16le_24000', pcm_44100: 'pcm_s16le_44100' };

  return async function ttsBackend(text, opts = {}) {
    const voiceId = opts.voiceId || defaultVoiceId;
    if (!voiceId) throw new Error('voiceId required');
    const outputFormat = opts.outputFormat || 'pcm_24000';
    // ElevenLabs takes output_format as a QUERY parameter (NOT a body field), and the Accept header must match it. The
    // prior code sent output_format in the BODY (ignored by the API) with a hardcoded accept:audio/pcm and a hardcoded
    // 'pcm_s16le_24000' return label — so a non-pcm request (e.g. /deck narration's mp3_44100_128, added for the
    // audio-size cap) was silently NOT honored and the bytes were mislabeled. Now the format is applied end-to-end
    // and labeled honestly, so the mp3 size savings actually take effect and the consumer can decode correctly.
    const accept = outputFormat.startsWith('mp3') ? 'audio/mpeg'
      : outputFormat.startsWith('ulaw') ? 'audio/basic'
      : 'audio/pcm';
    const url = `${baseUrl}/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=${encodeURIComponent(outputFormat)}`;
    const res = await fetchWithTimeout(doFetch, url, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey, 'content-type': 'application/json', accept },
      body: JSON.stringify({
        text,
        model_id: opts.modelId || 'eleven_flash_v2_5',
        voice_settings: toneToSettings(opts.tone),
      }),
    }, timeoutMs);
    if (!res || !res.ok) throw new Error('elevenlabs error ' + (res && res.status));
    const audio = Buffer.from(await res.arrayBuffer());
    if (audio.length === 0) throw new Error('elevenlabs returned empty audio');
    return { audio, format: PCM_LABELS[outputFormat] || outputFormat };
  };
}

/**
 * fetch with a hard timeout: aborts the request after timeoutMs so a hung or slow TTS server can never stall the
 * ring or the brief. On timeout the underlying fetch rejects (AbortError) and the caller fails closed — never an
 * open hang. An injected fetch that ignores the signal still resolves normally; real fetch honors it.
 */
async function fetchWithTimeout(doFetch, url, init, timeoutMs) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    return await doFetch(url, { ...init, signal: ac.signal });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The origin key used to vet a voiceUrl against the trusted set (SSRF defense-in-depth for createPocketTTSBackend).
 * http(s)/ws(s) -> URL.origin (scheme://host:port). Non-special schemes (e.g. hf://, s3://) have an opaque "null"
 * origin, so key on scheme//host (hf://voices/* all share hf://voices). Returns null for a non-string / unparseable
 * value, which is therefore never trusted.
 */
function voiceUrlOrigin(u) {
  if (typeof u !== 'string' || !u) return null;
  let parsed;
  try { parsed = new URL(u); } catch { return null; }
  if (parsed.origin && parsed.origin !== 'null') return parsed.origin;
  return parsed.host ? `${parsed.protocol}//${parsed.host}` : null;
}

/**
 * FREE, LOCAL TTS via kyutai pocket-tts `serve` (POST /tts, multipart form, audio/wav out). No API key, no per-char
 * cost — a 100M model on CPU (~8x realtime). SAME ttsBackend(text, opts) -> { audio, format } contract as
 * createElevenLabsBackend, so it's a drop-in swap selected by the composition root. pocket-tts has no native tone
 * control, so `tone` selects a pre-cloned per-tone voice from `toneVoices` when provided (our free "audio tags").
 * @param {{ baseUrl?:string, fetch?:Function, defaultVoiceUrl?:string, toneVoices?:Record<string,string>, timeoutMs?:number, allowedVoiceUrlOrigins?:string[] }} cfg
 * @returns ttsBackend(text, {tone,voiceUrl}) -> { audio: Buffer, format:'wav' }
 */
export function createPocketTTSBackend(cfg = {}) {
  const baseUrl = String(cfg.baseUrl || 'http://127.0.0.1:8000').replace(/\/+$/, '');
  const doFetch = cfg.fetch || globalThis.fetch;
  if (typeof doFetch !== 'function') throw new Error('no fetch implementation available');
  const toneVoices = cfg.toneVoices || {}; // { urgent:<voice_url>, calm:<voice_url>, warm:<voice_url> } — free tone approximation
  const timeoutMs = Number.isFinite(cfg.timeoutMs) && cfg.timeoutMs > 0 ? cfg.timeoutMs : 10_000; // hard cap: a hung pocket-tts serve fails closed, never hangs the ring/brief
  // SSRF defense-in-depth: the pocket-tts serve FETCHES voice_url server-side, so a caller-controlled voiceUrl is an
  // SSRF vector. Deploy-configured voiceUrls (toneVoices, defaultVoiceUrl) are trusted by origin; a CALLER-supplied
  // opts.voiceUrl is forwarded ONLY if its origin matches one of those (or an explicit cfg.allowedVoiceUrlOrigins) —
  // else it is ignored (falls back to the tone/default voice). The guard lives HERE so it holds even if a future
  // handler forwards opts.voiceUrl (today handleTts forwards only voiceId/tone, never a URL).
  const trustedVoiceOrigins = new Set(
    [cfg.defaultVoiceUrl, ...Object.values(toneVoices), ...(cfg.allowedVoiceUrlOrigins || [])]
      .map(voiceUrlOrigin)
      .filter(Boolean),
  );

  return async function ttsBackend(text, opts = {}) {
    const t = String(text ?? '');
    if (!t) throw new Error('text required');
    // A cloned per-tone voice stands in for ElevenLabs tone tags (pocket-tts has no prosody control). A CALLER
    // opts.voiceUrl wins ONLY if its origin is config-trusted (the SSRF guard above); else the tone→voice map, then
    // a configured default (else the server's built-in voice). An untrusted caller voiceUrl is dropped, never fetched.
    const configVoice = toneVoices[String(opts.tone || '').toLowerCase()] || cfg.defaultVoiceUrl;
    const callerVoice = opts.voiceUrl && trustedVoiceOrigins.has(voiceUrlOrigin(opts.voiceUrl)) ? opts.voiceUrl : undefined;
    const voiceUrl = callerVoice || configVoice;
    const form = new FormData();
    form.append('text', t);
    if (voiceUrl) form.append('voice_url', voiceUrl);
    const res = await fetchWithTimeout(doFetch, `${baseUrl}/tts`, { method: 'POST', body: form }, timeoutMs);
    if (!res || !res.ok) throw new Error('pocket-tts error ' + (res && res.status));
    const audio = Buffer.from(await res.arrayBuffer());
    if (audio.length === 0) throw new Error('pocket-tts returned empty audio');
    return { audio, format: 'wav' }; // 24kHz mono WAV
  };
}
