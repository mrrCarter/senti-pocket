// serve-brief.mjs — HTTP gateway wrapping the verified-briefing pipeline so the APP can POST a checkpoint
// and get back a REAL, signature-verified, LLM-grounded briefing + TTS audio. This is the SERVER half of the
// live-AI UPGRADE path (the phone POSTs here; brief-live.mjs is the one-shot CLI equivalent).
//
// HONEST posture (same as the phone): refuses (403) any checkpoint whose signature does not verify.
// Needs OPENAI_API_KEY (LLM briefing + default TTS). Optional ELEVENLABS_API_KEY for ElevenLabs voice.
//
//   OPENAI_API_KEY=sk-... node scripts/serve-brief.mjs [port]            # default port 8787
//
//   POST /brief  body {"checkpoint": {...}}  (checkpoint optional; omitted => bundled demo fixture)
//        -> 200 {verified:true, text, voice, audioBase64}   |   403 {verified:false} on bad signature
//   GET  /health -> {ok, keyed, voice}
//
// NOTE (honest chain to put this ON THE PHONE): needs (1) a key, (2) this service reachable from the device
// (host LAN IP or a tunnel — localhost won't reach a physical iPhone), (3) the app's HTTP client + audio
// playback (Pulse), (4) the Mac build. The on-device FLOOR (AVSpeech + on-device SFSpeech + crypto verify)
// needs NONE of this and is the robust demo; this endpoint is the live-cloud-voice STRETCH.
import { createServer } from 'node:http';
import { createPublicKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { verifyBundle } from '../src/bundle.mjs';

const OPENAI = process.env.OPENAI_API_KEY;
const ELEVEN = process.env.ELEVENLABS_API_KEY;
const ELEVEN_VOICE = process.env.ELEVENLABS_VOICE_ID || '21m00Tcm4TlvDq8ikWAM'; // Rachel (public default)
const PORT = Number(process.argv[2] || process.env.PORT || 8787);
const VOICE_LABEL = ELEVEN ? 'elevenlabs' : 'openai-tts';

// HONEST GATE: pinned Ed25519 trust anchor — same key the phone pins. Repository never self-mints trust.
const TRUST = { 'pocket-demo-app-fixture': 'SehNmI_dP9XFonEUXzmoDA7B0wCAss_JbVbbM4L0Y94' };
const DEFAULT_CP = fileURLToPath(new URL('../../../apps/SentiPocketApp/Resources/canonical_checkpoint.json', import.meta.url));

function verify(bundle) {
  const raw = TRUST[bundle?.signingKeyId];
  if (!raw) return false;
  return verifyBundle(bundle, createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: raw }, format: 'jwk' }));
}

const SYS = 'You are Senti, an AI that phones its founder with a spoken status briefing. Speak in second person, warm, concise (<=90 words), spoken-word cadence (no bullet chars, no markdown). Ground EVERY claim strictly in the provided checkpoint JSON; invent nothing. End with the single most important decision or blocker.';

async function llmBriefing(bundle) {
  const facts = JSON.stringify({ summary: bundle.summary, evidence: bundle.evidence, sessionId: bundle.sessionId }, null, 0);
  const chat = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST', headers: { Authorization: `Bearer ${OPENAI}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'gpt-4o-mini', temperature: 0.3,
      messages: [{ role: 'system', content: SYS }, { role: 'user', content: `Checkpoint (verified, signed):\n${facts}\n\nSpeak my briefing now.` }] }),
  });
  if (!chat.ok) throw new Error(`LLM ${chat.status}: ${(await chat.text()).slice(0, 200)}`);
  return (await chat.json()).choices[0].message.content.trim();
}

async function tts(text) {
  if (ELEVEN) {
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${ELEVEN_VOICE}`, {
      method: 'POST', headers: { 'xi-api-key': ELEVEN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, model_id: 'eleven_turbo_v2_5' }) });
    if (!r.ok) throw new Error(`ElevenLabs ${r.status}: ${(await r.text()).slice(0, 200)}`);
    return Buffer.from(await r.arrayBuffer());
  }
  const r = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST', headers: { Authorization: `Bearer ${OPENAI}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'gpt-4o-mini-tts', voice: 'shimmer', input: text }) });
  if (!r.ok) throw new Error(`OpenAI TTS ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return Buffer.from(await r.arrayBuffer());
}

createServer((req, res) => {
  const json = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'GET' && req.url === '/health') return json(200, { ok: true, keyed: !!OPENAI, voice: VOICE_LABEL });
  if (req.method === 'POST' && req.url === '/brief') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 2e6) req.destroy(); });
    req.on('end', async () => {
      try {
        let bundle;
        if (body.trim()) { const parsed = JSON.parse(body); bundle = parsed.checkpoint || parsed; }
        else { bundle = JSON.parse(readFileSync(DEFAULT_CP, 'utf8')); }
        if (!verify(bundle)) return json(403, { verified: false, error: 'checkpoint signature did not verify — refusing to brief on unverified data' });
        if (!OPENAI) return json(503, { verified: true, error: 'gateway has no OPENAI_API_KEY set' });
        const text = await llmBriefing(bundle);
        const audio = await tts(text);
        return json(200, { verified: true, text, voice: VOICE_LABEL, audioBase64: audio.toString('base64') });
      } catch (e) { return json(502, { error: String((e && e.message) || e) }); }
    });
    return;
  }
  json(404, { error: 'use POST /brief or GET /health' });
}).listen(PORT, () => console.log(`pocket-gateway briefing service on :${PORT} (keyed=${!!OPENAI}, voice=${VOICE_LABEL})`));
