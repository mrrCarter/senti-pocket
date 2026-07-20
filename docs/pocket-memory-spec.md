# Pocket Memory & Recall — design spec (v0.1)

**Author:** claude-warden · **Status:** draft blueprint for review (NOT a merge request) · **Source:** extracted from Carter's `ENGRAM-architecture-v3` (his personal-memory research), scoped down to Senti Pocket's checkpoint/session domain.

> **Read this first — sequencing discipline.** This is the **NEXT-phase** blueprint. It does **not** jump the queue ahead of the unproven **spine**: (1) a real message posting **phone → MCP → live Senti** (needs Carter's AS-registration GO), and (2) **E4B actually reasoning** over a checkpoint instead of emitting a fixture summary. The memory system is what makes recall *magical*, but we prove the loop first, then this compounds on top. Nothing here should be built before the spine is green.

---

## 1. Thesis — Pocket memory is small-data on-device

A heavy Senti user over years generates **thousands** of checkpoints and **tens of thousands** of evidence refs / agent utterances — not billions. ENGRAM's Thesis 1 applies with room to spare: the whole corpus fits on the phone, and the retrieval problem is a **sub-10ms personal-scale problem**, not a hyperscale one.

**The ANN plot twist (ENGRAM §7), stated for us:** at this scale you do **not** need a vector database. A few hundred-K int8 vectors × 512-d is ~200M multiply-accumulates — **<10ms with NEON SIMD**. An **exact brute-force scan is 100% recall by definition**, with zero index maintenance, zero tuning, and trivial metadata pre-filtering. Reach for HNSW (usearch/ObjectBox) **only** if a corpus ever passes ~1M vectors or on old hardware — one function's worth of abstraction boundary, deferred.

**Consequence:** the "95%+ recall" bar is not a hope. Exact scan gives 100% dense recall; the honest work is **fusion quality** (finding the *right* evidence across channels) and **reasoning over it**, not index recall.

---

## 2. Data model — tri-layer, immutable-facts (reuses our honesty wedge)

ENGRAM's load-bearing decision maps cleanly onto what Pocket already is: **observations are immutable facts; entities are mutable interpretations; bindings are reversible glue.** For Pocket this is a *gift* — it's the same tamper-evidence/immutability we already sell.

| ENGRAM concept | Pocket binding |
|---|---|
| `observation` (immutable) | a checkpoint **EvidenceRef** (id, ts, snippet, agentId, sequenceId) — already immutable, already inside the signed bundle |
| `entity` (mutable interpretation) | session · agent · checkpoint · topic · project |
| `binding` (reversible, audited) | evidence → entity links, method-stamped (`auto_knn`/`consolidator`/`user`) and reversible |
| `edge` (traversal graph) | `appeared_in` / `by_agent` / `in_session` / `about_topic` / `references_checkpoint`, weighted by co-occurrence + recency |
| `occurrence` (ACT-R fuel) | capture / view / listen / answer / act — engagement that raises a memory's activation |

```sql
-- Immutable facts: what the session/checkpoint actually contained
CREATE TABLE evidence (
  id TEXT PRIMARY KEY,           -- EvidenceRef.id (content-addressed)
  checkpoint_id TEXT, session_id TEXT, agent_id TEXT,
  sequence_id INTEGER, ts INTEGER,
  snippet TEXT,                  -- verbatim; FTS5-indexed
  embedding_id INTEGER,          -- FK into the int8 vector store
  extractor_ver INTEGER          -- model upgrade -> lazy re-embed, never a migration
);
CREATE VIRTUAL TABLE evidence_fts USING fts5(snippet, content='evidence', content_rowid='rowid');

CREATE TABLE entity (            -- mutable interpretation
  id INTEGER PRIMARY KEY, kind TEXT,   -- session|agent|checkpoint|topic|project
  label TEXT, state TEXT,              -- tentative|auto|user_labeled|tombstoned
  exemplars JSON                       -- canonical evidence ids (a set, not a centroid)
);
CREATE TABLE binding (
  evidence_id TEXT, entity_id INTEGER, confidence REAL,
  method TEXT, bound_at INTEGER, PRIMARY KEY (evidence_id, entity_id)
);
CREATE TABLE edge (
  src INTEGER, dst INTEGER, type TEXT, weight REAL,
  evidence_count INTEGER, first_seen INTEGER, last_seen INTEGER,
  PRIMARY KEY (src, dst, type)
);
CREATE TABLE occurrence ( entity_or_evidence INTEGER, kind TEXT, at INTEGER );
```

**Never destructively merge.** A bad merge is a *split*; a user correction is a *rebinding*. The signed-bundle spine is untouched — memory is derived, idempotently rebuildable from the immutable evidence, and never re-labels signed content as something it isn't (same discipline as PR #21's `MembershipAuthorizedCheckpoint` ≠ `VerifiedBundle`).

---

## 3. Retrieval — the fix for "no cache evidence / super brief"

Carter's build hit two failures: the briefing was **too brief** (E4B not reasoning over the checkpoint) and the gate **hard-refused** ("I don't have cache evidence for that"). Both are a **retrieval** problem, and ENGRAM §7 is the fix. Query path, p99 < 100ms, **no LLM in the hot path**:

| Stage | What | Budget |
|---|---|---|
| 1 | Query embed (EmbeddingGemma/MobileCLIP text tower) + entity-mention match | ~5ms |
| 2a | **Dense** candidates: exact int8 scan over evidence vectors | ~8ms |
| 2b | **Lexical** candidates: FTS5/BM25 over snippets, agent labels, checkpoint titles (parallel with 2a) | ~3ms |
| 3 | **RRF-pool** 2a + 2b + entity matches → candidate set; seed the session graph | ~1ms |
| 4 | Spreading activation (forward-push Personalized PageRank) over the session/checkpoint graph | ~5ms |
| 5 | Fusion score + optional late-interaction rerank of top ~100 | ~20ms |
| 6 | Assemble + **path evidence** ("this answer traces: your question → checkpoint cp_… → agent pulse → this line") | ~5ms |

**Why 2b matters (ENGRAM's line):** *dense embeddings are semantic geniuses and string idiots.* "The checkpoint where Omar 403'd," "the sessions:write scope decision," a literal PR number — those are **string** problems FTS5 solves for free. Reciprocal-rank fusion pools the ranked lists (rank-based, so incompatible score scales don't matter); the fusion model *orders* them.

**Then E4B reasons over the fused top-K** — not a one-line fixture summary. And on a genuine miss, the honest behavior is **a clarifying question** ("do you mean the auth-scope checkpoint from tonight, or the earlier gateway one?"), **not** a hard refuse. The refuse gate stays only for the truly-empty case, and even then it offers the nearest candidates.

**One-pass where multi-agent is overkill (Carter's point):** E4B is a single-pass multimodal reasoner — for "summarize this checkpoint" or "answer from this evidence set," it does not need a separate sidecar listener agent. Reserve multi-agent for genuine decomposition.

---

## 4. Recall as a control loop + the 8-Needle eval (Carter's bar, measured)

ENGRAM §6 step 9 / §11 turn "95%+ recall" from a claim into **two CI jobs** — exactly Carter's "8-needle @ >95%" phrase:

- **Needle-Chain** — plant chains of 8 memories linked only through shared entities (evidence → agent → session → topic → … → a later checkpoint). Query the head with a paraphrase; success = the tail in top-20. **Gate ≥ 95% chain completion.** (Tests *depth* through the graph.)
- **Needle-Scatter** — 8 relevant items dispersed across the corpus; the **pre-rerank candidate pool** must contain ≥ 95% of them. (Tests *breadth* across the corpus.)
- Plus: **recall@10 ≥ 0.95** vs exact ground truth (self-maintaining — the nightly consolidator brute-forces ground truth and auto-tunes), **p99 < 100ms** on-device.

This is the warden's kind of bar: **recall isn't hoped, it's measured**, and it fails closed if it regresses.

---

## 5. Storage, sync, cold-start

- **SQLite is the source of truth** on-device; vectors (sqlite-vec/usearch) + the CSR graph snapshot are **derived and idempotently rebuildable** — a crash re-runs a job, never corrupts state.
- **Sync = E2EE op-log** to a **thin cloud fabric** (ciphertext only; the server relays and stores no plaintext graph). This is Carter's "cache-on-phone + rest-on-cloud" done privacy-first — don't dump memories to S3 plaintext; keep source-of-truth on-device, spill only encrypted. Cheaper *and* it's the privacy moat.
- **Cold-start (ENGRAM §13):** front-load by indexing the user's **existing** Senti checkpoints/sessions on day one, so the first overnight consolidation wakes to years of re-associations. Day two should feel like Pocket has known your work for years.

---

## 6. Near-term product fixes (from the build feedback — these are NOW-lane, not memory)

1. **Audio-tagged speech.** Keep AVSpeech for now, but have the speech layer **emit ElevenLabs-style audio tags** in the generated text now, so switching providers later is a one-line change. AVSpeech strips/ignores tags; ElevenLabs consumes them.
2. **Online toggle + web-search.** The phone is usually online — auto-detect (or a visible toggle where the "offline cache evidence" copy lives). Online → agents get web-search + normal capability; offline → the honest cached path.
3. **Reasoning, not summary.** Wire E4B to reason over the retrieved checkpoint context (§3), which is what kills the "super brief / did blabla and stopped" feel.

---

## 7. MCP memory-substrate (platform, later — Carter's vision, already in ENGRAM §1/§12)

ENGRAM §1 wrote Carter's platform idea verbatim: *"don't compete with assistants — become their memory substrate; expose the graph via MCP so any assistant queries your memory with per-scope consent."* For us this is a natural extension of the hosted MCP-auth chain: expose Pocket memory as **scoped, consent-gated MCP tools**, where each cross-boundary grant is a **signed consent receipt** `{grantor, grantee, scope, ts, sig}` — which is **the same signed-ActionReceipt discipline** we already ship. Detached MCP services (ring-a-phone; narrate-a-deck → CDN audio/video URL) live here too. All of it **after** the phone proves the core loop.

---

## 8. Sequencing & ownership

| Phase | Work | Owner |
|---|---|---|
| **NOW** (spine) | E4B reasons over checkpoint context · audio-tagged speech · online toggle · retrieval-instead-of-hard-refuse · **the real write (phone→MCP→live Senti)** | Atlas / Relay / Forge; **gated by warden**; write blocked on Carter's AS-registration GO |
| **NEXT** | Memory MVP: FTS5 + dense int8 exact-scan + RRF over real checkpoints; Needle-Chain/Scatter CI | Relay (index service) + warden (spec/eval) |
| **LATER** | On-device graph + spreading activation + nightly consolidator + E2EE op-log sync | crew |
| **FUTURE** | MCP memory-substrate + detached narration/ring services | crew |

---

## 9. Honest open problems (ENGRAM §13, Pocket-scoped)

- **Entity-resolution under drift** — agents/sessions/topics rename; exemplar sets + reversible bindings mitigate; continuous eval is the discipline.
- **The empty-vs-close-enough line** — when to answer-with-caveat vs ask-a-clarifying-question vs honestly refuse. This is a product-judgment threshold; measure it.
- **Thermal/battery** — nightly consolidation on charger only; never co-schedule the LLM and heavy indexing.
- **Cold-start** — before the graph is dense the magic is sparse; day-one import of existing checkpoints is the answer.

---

*This spec is a blueprint for discussion, not a claim of built work. The retrieval math and evals are transplanted from ENGRAM v3 and must be validated on real Pocket corpora before any recall number is asserted.*
