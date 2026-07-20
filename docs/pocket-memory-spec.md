# Pocket Memory & Recall — canonical spec (v0.2)

**Design + eval owner:** claude-warden · **Implementation-contract co-author:** claude-pocket-atlas (the on-device Swift `PocketEngram` package that implements this design) · **Status:** draft blueprint for review (NOT a merge request) · **Source:** extracted from Carter's `ENGRAM-architecture-v3` (his personal-memory research), pointed at Senti Pocket's **session/checkpoint** corpus. Warden and Atlas reached the same ENGRAM essentials independently — that convergence is the validation; this is the one canonical doc (supersedes the two draft specs).

> **Read this first — sequencing discipline.** This is the **NEXT-phase** blueprint. It does **not** jump the queue ahead of the unproven **spine**: (1) a real message posting **phone → MCP → live Senti** (needs Carter's AS-registration GO), and (2) **E4B/gateway reasoning** over a checkpoint instead of a fixture summary. The memory system is what makes recall *magical*, but we prove the loop first, then this compounds on top. Nothing here is built before the spine is green.

---

## 1. Thesis — Pocket memory is small-data on-device

A heavy multi-year Senti user generates on the order of 10²–10³ sessions × hundreds of events ≈ **~500K observations** — not billions. ENGRAM's Thesis 1 applies with room to spare: the whole corpus fits on the phone, and recall is a **sub-10ms personal-scale problem**.

**The ANN plot twist (ENGRAM §7), stated for us:** at this scale you do **not** need a vector database. A few hundred-K int8 vectors × 512-d ≈ 200M multiply-accumulates — **<10ms with NEON SIMD**. An **exact brute-force scan is 100% recall by definition**, zero index maintenance, trivial metadata pre-filter. Reach for HNSW only past ~1M vectors or on old hardware — one function's worth of abstraction boundary, deferred.

**Consequence:** "95%+ recall" is not a hope. Exact scan gives 100% dense recall; the honest work is **fusion quality** (finding the right evidence across channels) and **grounded reasoning over it** — and this is *why* local-memory + local-reasoning beats a cloud assistant's lossy remembered summary: it's on your device, instant, private, and complete.

---

## 2. Data model — tri-layer, immutable-facts (reuses our honesty wedge)

ENGRAM's load-bearing decision maps onto what Pocket already is: **observations are immutable facts; entities are mutable interpretations; bindings are reversible glue.** For Pocket this is a *gift* — it's the same tamper-evidence/immutability we already sell. **Never destructively merge**: a bad merge is a *split*, a user correction is a *rebinding*, every identity decision is auditable and undoable.

| ENGRAM concept | Pocket binding |
|---|---|
| `observation` (immutable) | a checkpoint **EvidenceRef** (id, ts, snippet, agentId, sequenceId) — already immutable, already inside the signed bundle (the canonical binding; tighter than a raw "session-artifact") |
| `observation.kind` (extraction taxonomy) | `agent_claim · decision · file_touched · error · gate_verdict · tool_call · entity_mention` |
| `entity` (mutable interpretation) | `agent · session · topic · decision · repo · file · pr · moment ("that one time")` |
| `binding` (reversible, audited) | evidence→entity, `method ∈ {auto_knn, consolidator, user, cross_ref}` |
| `edge` (traversal graph) | `authored_by · in_session · about_topic · decided · touched_file · supersedes · references_pr · co_occurred_with`, weighted by co-occurrence + recency |
| `occurrence` (ACT-R fuel) | capture / recall / surface_engaged / acted_on — engagement that raises a memory's activation |

```sql
-- Immutable facts. The EvidenceRef IS the observation (content-addressed, signed-bundle-native).
CREATE TABLE evidence (
  id TEXT PRIMARY KEY,           -- EvidenceRef.id
  checkpoint_id TEXT, session_id TEXT, agent_id TEXT, sequence_id INTEGER, ts INTEGER,
  kind TEXT,                     -- agent_claim|decision|file_touched|error|gate_verdict|tool_call|entity_mention
  snippet TEXT,                  -- verbatim; FTS5-indexed
  embedding_id INTEGER, extractor_ver INTEGER   -- model upgrade -> lazy re-embed, never a migration
);
CREATE VIRTUAL TABLE evidence_fts USING fts5(snippet, content='evidence', content_rowid='rowid');

CREATE TABLE entity ( id INTEGER PRIMARY KEY, kind TEXT, label TEXT, state TEXT, exemplars JSON );  -- exemplars = a SET, not a centroid
CREATE TABLE binding ( evidence_id TEXT, entity_id INTEGER, confidence REAL, method TEXT, bound_at INTEGER, PRIMARY KEY (evidence_id, entity_id) );
CREATE TABLE edge ( src INTEGER, dst INTEGER, type TEXT, weight REAL, evidence_count INTEGER, first_seen INTEGER, last_seen INTEGER, PRIMARY KEY (src, dst, type) );
CREATE TABLE occurrence ( entity_or_evidence INTEGER, kind TEXT, at INTEGER );
```

The signed-bundle spine is untouched — memory is **derived, idempotently rebuildable** from the immutable evidence, and never re-labels signed content as something it isn't (same discipline as PR #21's `MembershipAuthorizedCheckpoint` ≠ `VerifiedBundle`). **Graph store:** plain SQLite + an in-memory CSR snapshot, two ops only (weighted push + bounded BFS) ≈ 300 lines of Swift; no embedded graph-DB dependency.

---

## 3. Encoder — three passes (sessions)

- **Pass 1 (sync, at capture, <50ms).** Index the artifact: text embedding (EmbeddingGemma/MobileCLIP text tower, Matryoshka-truncate to 256-d), FTS5 tokenize, parse `{session_id, seq, agent, ts}`. **The session is searchable the instant it lands.**
- **Pass 2 (opportunistic).** On-device **Gemma E4B** entity/relation extraction → typed structs (agents, decisions, files, PRs, topics). **Eager binding**: an observation that k-NN-matches a known entity above threshold binds now and emits a **recall trigger** ("this connects to the PR#418 provider-trust decision") — surfaced while the work is warm.
- **Pass 3 (overnight, on charger, `BGProcessingTask` + `requiresExternalPower`).** The full Consolidator (§5). Thermal discipline: never run Gemma and heavy indexing concurrently.

---

## 4. Retrieval — the fix for "no cache evidence / super brief"

Carter's build hit two failures: the briefing was **too brief** (reasoning over one bare checkpoint, no memory) and the gate **hard-refused** ("I don't have cache evidence for that"). Both are a **retrieval** problem, and ENGRAM §7 is the fix. Query path, p99 < 100ms, **no LLM in the hot path**:

| Stage | What | Budget |
|---|---|---|
| 1 | Query embed + entity-mention match | ~5ms |
| 2a | **Dense** candidates: exact int8 scan over evidence vectors (100% recall by definition) | ~8ms |
| 2b | **Lexical** candidates: FTS5/BM25 over snippets/labels (parallel with 2a) | ~3ms |
| 3 | **RRF-pool** 2a + 2b + entity matches → candidate set; seed the session graph | ~1ms |
| 4 | **Spreading activation** = forward-push Personalized PageRank over the session graph (α≈0.1 ⇒ deep diffusion; runtime independent of graph size) | ~5ms |
| 5 | Fusion score (logistic over cos + logPPR + ACT-R base-level + affinity) + late-interaction rerank of top ~100 | ~20ms |
| 6 | Assemble + **path evidence** ("query → session-951 → the trust-chain decision → PR#418 → this recap") | ~5ms |

**Why 2b matters:** *dense embeddings are semantic geniuses and string idiots.* "The checkpoint where Omar 403'd," a literal PR number, `sessions:write` — those are **string** problems FTS5 solves for free. RRF pools the ranked lists (rank-based; incompatible score scales don't matter); the fusion model orders them. **Reasoning is the slow-path RAG over the recalled set — never in the hot path.**

**This already has its first small landing in the spine.** The gateway's grounding-first `/answer` router (`routeAnswer` @ `29033f3`, warden-gated) *is* retrieval-grounded needling in miniature: it retrieves grounding from the verified checkpoint, and the **grounding** — not the LLM's self-confidence — routes `answered` / `clarify` / `unavailable(nearestTopics)`. `.answered` requires non-empty grounded citations; hallucinated cites are dropped. That is exactly this §4 discipline at checkpoint scale; the memory MVP generalizes it across all sessions.

---

## 5. Consolidator — overnight re-association (ENGRAM §6)

Retroactive binding via a **Pending Association Store** (parked observations re-scored only when an entity's exemplar set changes → work ∝ what improved, not corpus size); session/topic re-segmentation; edge-weight recompute (recency decay); and **precompute recall surfaces** — this is where **weekly standups**, "you're resuming session X, here's its history," and "you're about to touch file Y, here's every prior decision on it" get computed *while charging*, so the app feels psychic at open. Nightly **recall QA**: sample 100 queries, brute-force ground truth, verify recall@10 ≥ 0.95, auto-tune. **Recall is a control loop, not a hope.**

---

## 6. Recall as a control loop + the 8-Needle eval (Carter's bar, measured)

ENGRAM §6-step-9 / §11 turn "95%+ recall" into **two CI jobs** — exactly Carter's "8-needle @ >95%":

- **Needle-Chain ≥ 95%** (depth) — chains of 8 memories linked only through shared entities (evidence → agent → session → topic → … → a later checkpoint); query the head with a paraphrase; success = tail in top-20.
- **Needle-Scatter ≥ 95%** (breadth) — 8 relevant items dispersed; the **pre-rerank candidate pool** must contain ≥ 95%.
- Plus **recall@10 ≥ 0.95** vs exact ground truth (the nightly consolidator makes it self-maintaining), **p99 < 100ms** on-device, ER pairwise precision ≥ 0.995. Two CI jobs (Forge's on-device harness).

The warden's kind of bar: **recall is measured, not hoped**, and it fails closed if it regresses.

---

## 7. Storage, sync, cold-start

- **SQLite is the source of truth** on-device; vectors (sqlite-vec/usearch) + the CSR graph are **derived + idempotently rebuildable** — a crash re-runs a job, never corrupts state. int8, mmap'd (~35MB hot).
- **Sync = E2EE op-log** to a **thin cloud fabric** — append-heavy → causal-ordered ops, LWW scalars + set-union edges (not a full CRDT). **The server relays and stores ciphertext ONLY; it never holds a plaintext graph.** This is Carter's "cache-on-phone + rest-on-cloud" done privacy-first — *not* an S3 plaintext dump. An opt-in cold/low-end **vault tier** does server-side extraction only inside confidential-compute with **client-held keys** (still ciphertext at rest); opt-in, labeled, never the default. Cheaper *and* it's the privacy moat (ENGRAM Thesis 3: privacy IS scale).
- **Cold-start (ENGRAM §13):** front-load by indexing the user's **existing** Senti checkpoints/sessions on day one, so the first overnight consolidation wakes to years of re-associations. Day two should feel like Pocket has known your work for years.

---

## 8. Near-term product fixes (from the build feedback — NOW-lane, not memory)

1. **Audio-tagged speech** — keep AVSpeech now, but emit ElevenLabs-style audio tags in the generated text so the provider swap is one line. (Shipped + gated: `audio-tags.mjs` @ `ec71ac7`.)
2. **Online toggle + web-search** — auto-detect (or a visible toggle where the "offline cache evidence" copy lives). Online → agents get web-search; offline → the honest cached path (Atlas's `CheckpointFeed` connectivity states).
3. **Reasoning, not summary** — the `ReasoningProvider` seam feeds the gateway/E4B the checkpoint + needled context; `.clarify`/`.unavailable(nearestTopics)` replace the hard-refuse. Honest fallback: any cached fixture renders as `.cachedSample`, never posing as a live brief.

---

## 9. The MCP memory-substrate (platform, later — Carter's vision, ENGRAM §1/§12)

ENGRAM §1 wrote Carter's platform idea verbatim: *"don't compete with assistants — become their memory substrate; expose the graph via MCP with per-scope consent."* Pocket = the **coding/agent-work** memory substrate. `api.sentinelayer.com/mcp` exposes memory as scoped-consent tools any assistant can call:

- `memory.recall(query, scope) → [{memory, score, path_evidence}]` — ranked, with the "why" chain.
- `memory.needle(entity, hops) → chain` — the 8-hop story.
- `memory.timeline(session | topic | file) → ordered events`.
- `memory.standup(window) → precomputed digest`.

"Claude, ask my Senti memory about the trust-chain decision" → `memory.needle` → answer + receipt. Every assistant becomes a **distribution channel** for Pocket. Each cross-boundary grant is a **signed consent receipt** `{grantor, grantee, scope, ts, sig}` — the **same signed-ActionReceipt discipline** we already ship (warden's lane; aligns with AIdenID's crypto/receipt model). Scopes granular + revocable. Detached MCP services (ring-a-phone; narrate-a-deck → CDN audio/video URL) live here too. All of it **after** the phone proves the core loop.

---

## 10. Sequencing & ownership

| Phase | Work | Owner |
|---|---|---|
| **NOW** (spine) | gateway/E4B reasons over the checkpoint (grounding-routed) · audio-tagged speech · online toggle · retrieval-not-hard-refuse · **the real write (phone→MCP→live Senti)** | Atlas / Relay / Forge; **gated by warden**; write blocked on Carter's AS-registration GO |
| **NEXT** | Memory MVP: FTS5 + dense int8 exact-scan + RRF over real checkpoints; Needle-Chain/Scatter CI | Relay (index/MCP tools) · Atlas (`PocketEngram` on-device contract) · warden (spec/eval) |
| **LATER** | On-device graph + spreading activation + nightly consolidator + E2EE op-log sync | crew · Echo (Gemma slow-path RAG + Pass-2 extraction) when back |
| **FUTURE** | MCP memory-substrate + detached narration/ring services + confidential-compute vault tier | crew |

---

## 11. How this fixes the "absolutely bad build" (why it's not premature)

- **Shallow briefing** ("two agents did blabla then stopped"): the model was fed ONE checkpoint with no memory. With recall, reasoning runs over the checkpoint **+ the relevant past sessions it needled** → a rich, specific brief.
- **"no cache evidence" refusal**: Q&A **needles near-answers across all sessions** before reasoning → it finds the remotely-close thing or asks a clarifying question, never a hard refuse. Recall is the retrieval; the LLM is the reasoning; neither is the shallow fixture.

---

## 12. Honest open problems (ENGRAM §13, Pocket-scoped)

- **Entity-resolution under drift** — agents/sessions/topics rename; exemplar sets + reversible bindings mitigate; continuous eval is the discipline.
- **The empty-vs-close-enough line** — answer-with-caveat vs clarifying-question vs honest-refuse is a product-judgment threshold; measure it (and route on grounding, never on LLM self-confidence).
- **Thermal/battery** — nightly consolidation on charger only; never co-schedule the LLM and heavy indexing.
- **Cold-start** — before the graph is dense the magic is sparse; day-one import of existing checkpoints is the answer.

---

*This spec is a blueprint for discussion, not a claim of built work. The retrieval math and evals are transplanted from ENGRAM v3 and must be validated on real Pocket corpora before any recall number is asserted. Review asks: warden owns the MCP consent-scope + E2EE posture; Relay the index/gateway/vault boundary; Forge the 8-needle CI feasibility on-device.*
