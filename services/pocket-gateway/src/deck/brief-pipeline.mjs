// brief-pipeline.mjs — a STATE-MACHINED, sub-agent briefing pipeline over INJECTED Gemma sub-agents.
//
// WHY (Carter's directive): "ensure Gemma is used with well-designed state-machined sub-agents." The shipped brief()
// asks ONE Gemma call to outline + write + ground + tone all at once. This decomposes that into BOUNDED sub-agents
// sequenced by an EXPLICIT state machine with a fail-closed grounding gate BETWEEN stages:
//
//     PLAN ──▶ DRAFT ──▶ VERIFY ──▶ DONE
//       │        │          │
//       └────────┴──────────┴──▶ UNAVAILABLE   (any stage that yields nothing GROUNDED terminates honestly)
//
//   • PLAN  (sub-agent: outliner) — from the verified bundle, propose an ordered list of briefing POINTS, each tagged
//           with the candidate grounded evidence it covers. A point with no grounded evidence is not worth drafting.
//   • DRAFT (sub-agent: per-point writer) — write ONE concise, cited segment per surviving point. One point at a time,
//           so a single bad/empty draft drops only THAT point, never the whole brief.
//   • VERIFY (PURE gate, no Gemma) — reuse the SHIPPED grounding discipline (gemma-backend.brief / handlers.handleBrief):
//           a segment's cites must survive the intersection with the verified-bundle grounding set, else the segment is
//           dropped. If NOTHING survives, the terminal state is UNAVAILABLE — never a fabricated or ungrounded briefing.
//
// HONEST SCOPE: this module is PURE ORCHESTRATION — the two Gemma calls are INJECTED (plan, draft), same dependency-
// injection contract as ttsBackend / deps.reason. So the state machine + every fail-closed transition is DETERMINISTIC
// and unit-testable with a mocked backend (no native dep, no live endpoint). What this module does NOT establish is that
// the multi-stage pipeline produces BETTER briefings than single-shot brief() — that is a QUALITY question answerable only
// by a real-Gemma eval (see scripts/gemma-brief-pipeline-smoke.mjs). This module guarantees STRUCTURE + GROUNDING + fail-
// closedness, not quality uplift. It is drop-in for handleBrief: its brief() matches deps.brief's shape exactly.

/** The set of evidence ids retrieval found in the VERIFIED bundle — the only ids a citation may reference. */
function groundingSet(groundedEvidenceIds) {
  return new Set(Array.isArray(groundedEvidenceIds) ? groundedEvidenceIds.filter((id) => typeof id === 'string' && id.length > 0) : []);
}

/** Intersect a claimed-id list with the grounding set, deduped, order-preserving. Hallucinated ids are dropped. */
function keepGrounded(claimed, grounded) {
  const seen = new Set();
  const out = [];
  for (const id of Array.isArray(claimed) ? claimed : []) {
    if (typeof id === 'string' && grounded.has(id) && !seen.has(id)) { seen.add(id); out.push(id); }
  }
  return out;
}

/** Normalize one drafted segment to the shipped { text, taggedText?, evidenceIds } shape, cites grounding-filtered. */
function normalizeSegment(raw, grounded) {
  const s = raw && typeof raw === 'object' ? raw : {};
  const evidenceIds = keepGrounded(s.evidenceIds, grounded);
  const seg = {
    text: typeof s.text === 'string' ? s.text : '',
    evidenceIds,
  };
  if (typeof s.taggedText === 'string' && s.taggedText.length > 0) seg.taggedText = s.taggedText;
  return seg;
}

/** A segment crosses the VERIFY gate only if it has display text AND at least one grounded citation. */
function isGrounded(seg) {
  return !!seg && typeof seg.text === 'string' && seg.text.trim().length > 0 && Array.isArray(seg.evidenceIds) && seg.evidenceIds.length > 0;
}

/**
 * Build the state-machined briefing pipeline over injected Gemma sub-agents.
 *
 * @param {object} deps
 * @param {(a:{bundle:object, groundedEvidenceIds:string[]}) => Promise<{points:Array<{label?:string, evidenceIds?:string[]}>}>} deps.plan
 *   PLAN sub-agent: propose ordered briefing points, each with candidate evidence ids. Throw / empty -> UNAVAILABLE.
 * @param {(a:{point:object, bundle:object, groundedEvidenceIds:string[]}) => Promise<{text?:string, taggedText?:string, evidenceIds?:string[]}>} deps.draft
 *   DRAFT sub-agent: write one cited segment for a point. Throw / empty -> that point drops (not the whole brief).
 * @param {number} [deps.maxPoints=6]    hard cap on planned points fed to DRAFT (bounds sub-agent fan-out).
 * @param {number} [deps.maxSegments=6]  hard cap on segments that reach the terminal brief (bounds output).
 * @returns {{ brief: (a:{bundle:object, groundedEvidenceIds:string[]}) => Promise<{segments:Array<object>, plan:Array<object>, status:'briefed'|'unavailable', trace:string[]}> }}
 *   brief() is drop-in for deps.brief: handleBrief re-applies the SAME grounding filter downstream, so this is defense-in-depth.
 */
export function createBriefPipeline({ plan, draft, maxPoints = 6, maxSegments = 6 } = {}) {
  if (typeof plan !== 'function' || typeof draft !== 'function') {
    throw new Error('createBriefPipeline: plan and draft sub-agents are required (injected Gemma calls)');
  }
  const cap = (n, d) => (Number.isInteger(n) && n > 0 && n <= 100 ? n : d);
  const pointCap = cap(maxPoints, 6);
  const segCap = cap(maxSegments, 6);

  return {
    async brief({ bundle, groundedEvidenceIds } = {}) {
      const grounded = groundingSet(groundedEvidenceIds);
      const trace = ['plan'];
      // Empty grounding -> nothing can be cited -> UNAVAILABLE before any sub-agent call (fail-fast, no wasted Gemma).
      if (grounded.size === 0) return { segments: [], plan: [], status: 'unavailable', trace: [...trace, 'unavailable'] };

      // ── PLAN ───────────────────────────────────────────────────────────────────────────────────────────────────
      let planned;
      try { planned = await plan({ bundle, groundedEvidenceIds }); }
      catch { return { segments: [], plan: [], status: 'unavailable', trace: [...trace, 'unavailable'] }; }
      const rawPoints = planned && Array.isArray(planned.points) ? planned.points : [];
      // Keep only points that reference at least one GROUNDED evidence id — an ungrounded point is not worth drafting.
      const points = [];
      for (const p of rawPoints) {
        if (points.length >= pointCap) break;
        const evidenceIds = keepGrounded(p && p.evidenceIds, grounded);
        if (evidenceIds.length === 0) continue;
        points.push({ label: typeof (p && p.label) === 'string' ? p.label : '', evidenceIds });
      }
      if (points.length === 0) return { segments: [], plan: [], status: 'unavailable', trace: [...trace, 'unavailable'] };

      // ── DRAFT ──────────────────────────────────────────────────────────────────────────────────────────────────
      trace.push('draft');
      const drafted = [];
      for (const point of points) {
        let seg;
        try { seg = await draft({ point, bundle, groundedEvidenceIds }); }
        catch { continue; } // per-point fail-closed: one bad draft drops its point, never the whole brief
        drafted.push(normalizeSegment(seg, grounded));
      }

      // ── VERIFY (pure grounding gate) ───────────────────────────────────────────────────────────────────────────
      trace.push('verify');
      const segments = drafted.filter(isGrounded).slice(0, segCap);
      if (segments.length === 0) return { segments: [], plan: points, status: 'unavailable', trace: [...trace, 'unavailable'] };

      // ── DONE ───────────────────────────────────────────────────────────────────────────────────────────────────
      return { segments, plan: points, status: 'briefed', trace: [...trace, 'done'] };
    },
  };
}
