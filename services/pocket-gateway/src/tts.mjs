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
  if (!apiKey) throw new Error('ElevenLabs apiKey required (server-side only)');
  if (typeof doFetch !== 'function') throw new Error('no fetch implementation available');

  return async function ttsBackend(text, opts = {}) {
    const voiceId = opts.voiceId || defaultVoiceId;
    if (!voiceId) throw new Error('voiceId required');
    const url = `${baseUrl}/v1/text-to-speech/${encodeURIComponent(voiceId)}`;
    const res = await doFetch(url, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey, 'content-type': 'application/json', accept: 'audio/pcm' },
      body: JSON.stringify({
        text,
        model_id: opts.modelId || 'eleven_flash_v2_5',
        output_format: opts.outputFormat || 'pcm_24000',
        voice_settings: toneToSettings(opts.tone),
      }),
    });
    if (!res || !res.ok) throw new Error('elevenlabs error ' + (res && res.status));
    const audio = Buffer.from(await res.arrayBuffer());
    if (audio.length === 0) throw new Error('elevenlabs returned empty audio');
    return { audio, format: 'pcm_s16le_24000' };
  };
}
