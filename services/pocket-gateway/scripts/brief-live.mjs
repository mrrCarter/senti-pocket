// brief-live.mjs — LIVE AI briefing + voice, turnkey the instant a key is set. Zero-dep (Node 20 global fetch).
// Grounds a spoken briefing on a SIGNATURE-VERIFIED checkpoint, so the "AI speaks your briefing" moment is REAL
// (live LLM) and honest (refuses if the bundle doesn't verify). Voice: OpenAI TTS by default, ElevenLabs if its key is set.
//
//   OPENAI_API_KEY=sk-... node scripts/brief-live.mjs [checkpoint.json] [out.mp3]
//   ELEVENLABS_API_KEY=... [ELEVENLABS_VOICE_ID=...] OPENAI_API_KEY=sk-... node scripts/brief-live.mjs   # 11labs voice
//
// Prints the LLM briefing text + writes the spoken audio to out.mp3. No key => prints exactly what's missing and exits 2.
import { readFileSync, writeFileSync } from 'node:fs';
import { createPublicKey } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { verifyBundle } from '../src/bundle.mjs';

const OPENAI = process.env.OPENAI_API_KEY;
const ELEVEN = process.env.ELEVENLABS_API_KEY;
const ELEVEN_VOICE = process.env.ELEVENLABS_VOICE_ID || '21m00Tcm4TlvDq8ikWAM'; // Rachel (public default)
if (!OPENAI) { console.error('SET OPENAI_API_KEY (LLM briefing). Optional: ELEVENLABS_API_KEY for 11labs voice.'); process.exit(2); }

const inPath = process.argv[2] || fileURLToPath(new URL('../../../apps/SentiPocketApp/Resources/canonical_checkpoint.json', import.meta.url));
const outPath = process.argv[3] || 'C:/tmp/senti_briefing.mp3';
const bundle = JSON.parse(readFileSync(inPath, 'utf8'));

// HONEST GATE: only brief on a verified bundle (same posture as the phone). Trust store resolves the pinned key.
const TRUST = { 'pocket-demo-app-fixture': 'SehNmI_dP9XFonEUXzmoDA7B0wCAss_JbVbbM4L0Y94' };
const pinnedRaw = TRUST[bundle.signingKeyId];
const verified = pinnedRaw
  ? verifyBundle(bundle, createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: pinnedRaw }, format: 'jwk' }))
  : false;
if (!verified) { console.error('REFUSED: checkpoint signature did not verify — will not brief on unverified data.'); process.exit(3); }

// Ground the LLM strictly on the checkpoint summary/evidence — no invention.
const facts = JSON.stringify({ summary: bundle.summary, evidence: bundle.evidence, sessionId: bundle.sessionId }, null, 0);
const sys = 'You are Senti, an AI that phones its founder with a spoken status briefing. Speak in second person, warm, concise (<=90 words), spoken-word cadence (no bullet chars, no markdown). Ground EVERY claim strictly in the provided checkpoint JSON; invent nothing. End with the single most important decision or blocker.';
const chat = await fetch('https://api.openai.com/v1/chat/completions', {
  method: 'POST', headers: { Authorization: `Bearer ${OPENAI}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ model: 'gpt-4o-mini', temperature: 0.3,
    messages: [{ role: 'system', content: sys }, { role: 'user', content: `Checkpoint (verified, signed):\n${facts}\n\nSpeak my briefing now.` }] }),
});
if (!chat.ok) { console.error('LLM error', chat.status, (await chat.text()).slice(0, 300)); process.exit(4); }
const text = (await chat.json()).choices[0].message.content.trim();
console.log('\n=== Senti is calling — LIVE briefing (signature VERIFIED ✓) ===\n' + text + '\n');

// Voice: ElevenLabs if keyed, else OpenAI TTS.
let audio;
if (ELEVEN) {
  const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${ELEVEN_VOICE}`, {
    method: 'POST', headers: { 'xi-api-key': ELEVEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, model_id: 'eleven_turbo_v2_5' }) });
  if (!r.ok) { console.error('ElevenLabs error', r.status, (await r.text()).slice(0, 200)); process.exit(5); }
  audio = Buffer.from(await r.arrayBuffer());
} else {
  const r = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST', headers: { Authorization: `Bearer ${OPENAI}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'gpt-4o-mini-tts', voice: 'shimmer', input: text }) });
  if (!r.ok) { console.error('OpenAI TTS error', r.status, (await r.text()).slice(0, 200)); process.exit(5); }
  audio = Buffer.from(await r.arrayBuffer());
}
writeFileSync(outPath, audio);
console.log(`voice: ${ELEVEN ? 'ElevenLabs' : 'OpenAI TTS'} -> ${outPath} (${audio.length} bytes). Play it — that's the live AI briefing.`);
