// gemma-backend.mjs — deps.reason + deps.brief backed by Gemma via an OpenAI-compatible /chat/completions endpoint.
//
// Carter (2026-07-21): "make sure Gemma is being used." On-device Gemma (echo's LiteRT-LM) is build-blocked, and the
// gateway's /answer + /brief were UNWIRED in prod (deps.reason/deps.brief undefined => 501). This lights them up with a
// real Gemma, and ONE OpenAI-compatible client serves BOTH key-free-capable paths:
//   - LOCAL Ollama:  baseUrl 'http://localhost:11434/v1', model 'gemma3',       NO apiKey  -> real Gemma, zero cost, key-free
//   - Google AI Studio (OpenAI-compat): baseUrl 'https://generativelanguage.googleapis.com/v1beta/openai',
//                    model 'gemma-3-27b-it', apiKey <free AI Studio key>
//
// GROUNDING-FIRST + fail-closed (the honesty bar): the model may cite ONLY evidence ids present in the VERIFIED bundle;
// a non-JSON / errored / ungrounded response degrades to empty -> routeAnswer routes it to clarify/unavailable, NEVER a
// fabricated answer. handlers.mjs (routeAnswer / handleBrief) re-apply the SAME grounding intersection downstream, so
// this backend is defense-in-depth, not the sole gate. Zero-dep, injected fetch (deploy owns transport), never logs.

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_EVIDENCE = 24;   // bound the grounding context sent to the model
const SNIPPET_CAP = 280;   // per-evidence excerpt bytes (already bounded upstream by summarize.mjs)

/** Grounding context lines: `[id] (author @seq N) snippet` — the ids the model is allowed to cite. */
function evidenceLines(bundle) {
  const ev = Array.isArray(bundle?.evidence) ? bundle.evidence.slice(0, MAX_EVIDENCE) : [];
  return ev
    .map((e) => `[${e.id}] (${e.agentId || '?'} @seq ${e.sequence ?? '?'}) ${String(e.snippet || '').slice(0, SNIPPET_CAP)}`)
    .join('\n');
}
const groundedSet = (bundle, groundedEvidenceIds) => new Set(
  // PROVIDED (even an explicit []) -> use verbatim: an empty retrieval set must ground against NOTHING (fail-closed),
  // not silently fall back to the whole bundle (which would leak full-bundle citations). Only DERIVE from the bundle
  // when the caller passed no grounding at all (null/undefined/non-array).
  Array.isArray(groundedEvidenceIds)
    ? groundedEvidenceIds
    : (Array.isArray(bundle?.evidence) ? bundle.evidence : []).map((e) => e && e.id).filter(Boolean),
);

/** Robust JSON extraction: strict parse first, else the outermost {...} (models sometimes wrap JSON in prose/fences). */
function safeJson(raw) {
  if (typeof raw !== 'string') return null;
  try { return JSON.parse(raw); } catch { /* fall through */ }
  const a = raw.indexOf('{'); const b = raw.lastIndexOf('}');
  if (a >= 0 && b > a) { try { return JSON.parse(raw.slice(a, b + 1)); } catch { /* give up */ } }
  return null;
}

const normTopics = (topics, grounded) =>
  (Array.isArray(topics) ? topics : [])
    .filter((t) => t && typeof t.label === 'string' && typeof t.evidenceId === 'string' && grounded.has(t.evidenceId))
    .slice(0, 8)
    .map((t) => ({ label: t.label, evidenceId: t.evidenceId }));

const REASON_SYS =
  'You are a STRICTLY GROUNDED assistant. Answer ONLY from the EVIDENCE provided. Cite the evidence ids you actually '
  + 'used. If the evidence does not answer the question, return an empty text and cite nothing (do NOT guess). Respond '
  + 'as STRICT JSON, no prose: {"text": string, "taggedText": string, "evidenceIds": string[], "confidence": number '
  + 'between 0 and 1, "nearestTopics": [{"label": string, "evidenceId": string}]}. "taggedText" is "text" with optional '
  + 'audio emotion tags like [warm] or [emphasis]; keep "text" the plain version.';

const BRIEF_SYS =
  'You are a STRICTLY GROUNDED briefing assistant. Produce a concise SEGMENTED audio briefing from the EVIDENCE only. '
  + 'Every segment MUST cite the evidence ids it summarizes; never include a segment with no grounded evidence. Respond '
  + 'as STRICT JSON, no prose: {"segments":[{"text":string,"taggedText":string,"evidenceIds":string[]}]}. "taggedText" '
  + 'is "text" with optional audio emotion tags.';

/**
 * @param {object}   cfg
 * @param {string}   cfg.baseUrl    OpenAI-compatible ORIGIN (e.g. 'http://localhost:11434/v1' for Ollama). '/chat/completions' is appended.
 * @param {string}   [cfg.model]    model id ('gemma3' for Ollama; 'gemma-3-27b-it' for AI Studio). Default 'gemma3'.
 * @param {string}   [cfg.apiKey]   OPTIONAL bearer (AI Studio). Omit for a local key-free Ollama.
 * @param {Function} [cfg.fetch]    injected fetch (default global).
 * @param {number}   [cfg.timeoutMs]
 * @returns {{ reason: Function, brief: Function, model: string, baseUrl: string }}
 */
export function createGemmaBackend({ baseUrl, model = 'gemma3', apiKey, fetch = globalThis.fetch, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  if (typeof fetch !== 'function') throw new Error('createGemmaBackend: fetch is required');
  const base = String(baseUrl || '').replace(/\/+$/, '');
  if (!base) throw new Error('createGemmaBackend: baseUrl is required (e.g. http://localhost:11434/v1 for Ollama, or the AI Studio OpenAI-compat URL)');

  async function chat(messages) {
    const signal = (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') ? AbortSignal.timeout(timeoutMs) : undefined;
    const res = await fetch(`${base}/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        // apiKey ONLY in the Authorization header (never logged); omitted entirely for key-free Ollama.
        ...(apiKey ? { authorization: `Bearer ${apiKey}` } : {}),
      },
      // response_format nudges JSON on servers that support it (AI Studio); the prompt also demands JSON + safeJson is
      // robust, so an Ollama build that ignores response_format still works.
      body: JSON.stringify({ model, messages, temperature: 0.2, response_format: { type: 'json_object' } }),
      ...(signal ? { signal } : {}),
    });
    if (!res || !res.ok) throw new Error(`gemma backend HTTP ${res && res.status}`);
    const j = await res.json();
    const content = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
    if (typeof content !== 'string') throw new Error('gemma backend: response had no message content');
    return content;
  }

  return {
    model,
    baseUrl: base,

    // deps.reason({ question, bundle, groundedEvidenceIds }) -> { text, taggedText, evidenceIds, llmConfidence, nearestTopics }
    async reason({ question, bundle, groundedEvidenceIds } = {}) {
      const grounded = groundedSet(bundle, groundedEvidenceIds);
      const user = `QUESTION:\n${String(question || '').slice(0, 4096)}\n\nEVIDENCE (id, author, snippet):\n${evidenceLines(bundle) || '(none)'}`;
      let raw;
      try { raw = await chat([{ role: 'system', content: REASON_SYS }, { role: 'user', content: user }]); }
      catch { return { text: '', evidenceIds: [], llmConfidence: 0, nearestTopics: [] }; } // fail-closed -> unavailable
      const p = safeJson(raw);
      if (!p) return { text: '', evidenceIds: [], llmConfidence: 0, nearestTopics: [] };
      const evidenceIds = [...new Set((Array.isArray(p.evidenceIds) ? p.evidenceIds : []).filter((id) => grounded.has(id)))]; // grounding-first
      // GROUNDED-FIRST at the BACKEND (parity with brief()'s ungrounded-segment drop + the module's "ungrounded -> empty"
      // header): if NO citation survives the grounding filter, the answer is ungrounded -> return empty text. routeAnswer
      // also gates this (citedGrounded===0 -> clarify/unavailable), so this is defense-in-depth; nearestTopics is kept so
      // routeAnswer can still build a grounded clarify. (Forge cross-review: reason() previously kept text when cites emptied.)
      const groundedAnswer = evidenceIds.length > 0;
      return {
        text: groundedAnswer && typeof p.text === 'string' ? p.text : '',
        taggedText: groundedAnswer && typeof p.taggedText === 'string' ? p.taggedText : undefined,
        evidenceIds,
        llmConfidence: typeof p.confidence === 'number' ? Math.max(0, Math.min(1, p.confidence)) : undefined,
        nearestTopics: normTopics(p.nearestTopics, grounded),
      };
    },

    // deps.brief({ bundle, groundedEvidenceIds }) -> { segments: [{ text, taggedText, evidenceIds }] }
    async brief({ bundle, groundedEvidenceIds } = {}) {
      const grounded = groundedSet(bundle, groundedEvidenceIds);
      const user = `EVIDENCE (id, author, snippet):\n${evidenceLines(bundle) || '(none)'}`;
      let raw;
      try { raw = await chat([{ role: 'system', content: BRIEF_SYS }, { role: 'user', content: user }]); }
      catch { return { segments: [] }; } // fail-closed -> handleBrief returns grounded:false
      const p = safeJson(raw);
      if (!p || !Array.isArray(p.segments)) return { segments: [] };
      const segments = p.segments
        .map((s) => ({
          text: typeof s?.text === 'string' ? s.text : '',
          taggedText: typeof s?.taggedText === 'string' ? s.taggedText : undefined,
          evidenceIds: [...new Set((Array.isArray(s?.evidenceIds) ? s.evidenceIds : []).filter((id) => grounded.has(id)))],
        }))
        .filter((s) => s.text && s.evidenceIds.length > 0); // grounding-first (handleBrief re-filters too)
      return { segments };
    },
  };
}
