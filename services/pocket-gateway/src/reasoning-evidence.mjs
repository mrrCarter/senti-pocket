// One evidence projection shared by drafting and assessment. Both see the same admitted excerpts.
export const REASONING_EVIDENCE_LIMIT = 24;
export const REASONING_SNIPPET_CHAR_LIMIT = 280;

export function projectReasoningEvidence(evidence, ids) {
  const byId = new Map((Array.isArray(evidence) ? evidence : []).map((e) => [e?.id, e]));
  return [...new Set(Array.isArray(ids) ? ids : [])].slice(0, REASONING_EVIDENCE_LIMIT)
    .flatMap((id) => {
      const e = byId.get(id);
      if (!e) return [];
      const chars = [...String(e.snippet || '')];
      return [{ id: e.id, sequence: e.sequence, agentId: e.agentId || '?', ts: e.ts || '',
        snippet: chars.slice(0, REASONING_SNIPPET_CHAR_LIMIT).join(''),
        originalSnippetChars: chars.length, snippetTruncated: chars.length > REASONING_SNIPPET_CHAR_LIMIT }];
    });
}
