# Call-Me + Voice-Plane Contract (v0.2 — proposal)

The **one wire contract** that keeps machine (transport) and forge (voice layer + CLI) from colliding, per bundle's seam ruling (respawn 0a0d1325, reply to 430766). Grounded in the LIVE gateway — `services/pocket-gateway/API.md` + `src/need-carter-dial.mjs` + `src/handlers.mjs` — not invented from prose.

**v0.2 folds bundle's shape-gate amendments (430770):** AMEND-1 rate surface / 429, AMEND-2 verified source (server-stamped caller), AMEND-3 `policyVersion`/`policyHash` on RoutingDecision, DECLARE-1 answer-path out-of-scope. Machine still owes the transport-half confirmation; warden two-keys.

**SCOPE (DECLARE-1):** this specs the **RING only** (agent → owner's phone). The **ANSWER path** (owner's decision → the requesting box/CLI) is **OUT OF SCOPE for v0.2**, owner = **machine** (it is transport-shaped) for a future v0.3 — so nobody wires answers through an unauthenticated side door. Today the answer already lands the governed way: the owner's spoken decision posts as a `humanMessage` into the same Senti session via `/actions/execute` (existing), and the box reads it back off the session — no new answer channel needed for v0.2.

Ownership recap (bundle):
- **machine** — box/firecracker/warmstore/egress + the CALL-ME transport (gateway/APNs) + scoped-token mint + media-plane host wiring.
- **forge** — the voice layer (TTS/STT clients for phone/web/CLI/MCP) + the `call-me` CLI + the Gemma routing worker.
- **bundle** gates the contract shape; **warden** two-keys the PRs; ENGRAM/receipt (B3) bolts on later.

---

## 1. Call-Me wire contract (the trigger)

**Endpoint:** `POST {GATEWAY}/dial/ring-owner`

**Auth (fail-closed):** `Authorization: Bearer <Senti user-session token>`.
- The **human target is derived server-side from the bearer, NEVER from the body** (`ConsumerAccount.id`) — confused-deputy-safe: an agent rings *the verified owner*, and cannot redirect the ring by lying in the payload.
- Requires scope **`pocket:dial`** + **server-derived contributor|admin|owner** membership on `sessionId` (gateway calls `GET /api/v1/sessions/{id}/membership` under the exact bearer). Viewer is insufficient.
- **Verified SOURCE (AMEND-2), symmetric with verified target:** the scoped box token is minted bound to an **agent subject**, so the server **STAMPS the caller identity (`who`) from the token subject** — not from the body. Body `callerName` is **display-secondary at most** and never trusted as identity: a token holder cannot ring *as* `claude-warden`. Same confused-deputy discipline applied to the source, not only the target.

**Request body:**
```json
{
  "sessionId": "<member session the ring is ABOUT>",
  "kind": "info | checkpointReady | decisionYours | pickOption | go",
  "message": "<the need/question, 1..4096 UTF-8 bytes, required>",
  "options": ["a", "b"],          // REQUIRED (>=1) iff kind=pickOption; else omit
  "callerName": "claude-forge",   // display: WHO is asking (bounded, safe-fallback "Senti needs you")
  "context": "…",                  // optional, best-effort scrubbed + bounded before it leaves
  "priority": "normal | high",
  "checkpointId": "…",             // optional (checkpointReady)
  "idempotencyKey": "<optional; else server content-hashes intent>"
}
```
- **Write-kinds** (`decisionYours | pickOption | go`) carry a governed decision. `pickOption` with no options → **400** (atomic with its options).

**Push model (Warden's LEAN doorbell):** the server builds the canonical `NeedCarterSignal`, stores it, generates an **opaque gateway `dialId`**, and pushes a **LEAN doorbell** — CORE fields only (`v/id/kind/priority/callerName/who/sessionId/checkpointId?/fetch/ts`) — via APNs VoIP to the owner's registered device(s). **Governed content (message/options/context/evidenceSeqs/confidence) is NOT in the push.**

**Hydration:** the phone fetches governed content via `GET {GATEWAY}/dial?id=<dialId>` under its **own** bearer (scope `pocket:dial`). Any miss/nonmember/expired → uniform opaque **410** `{error:"dial signal unavailable",reason:"gone"}`, `Cache-Control: no-store`.

**Response:** `200 {dialId, dispatched:true}`.
**Errors:** 400 (message/options) · 401 (bad/absent bearer) · 403 (scope/nonmember/role) · 413 (message > 4096 bytes) · **429 (`rate_limited`, with `Retry-After`) — AMEND-1** · 501 (`dial-not-configured`) · 503 (retryable membership/backend).

**Rate surface (AMEND-1):** the token mint has caps, but a looping box with a valid token could ring-spam the owner's phone via APNs. So the endpoint enforces **per-token AND per-session ring rate limits** and returns **429 `{error:"rate_limited"}` + `Retry-After`** when exceeded. The `call-me` CLI **honors `Retry-After`, backs off with bounded retries, then exits non-zero** — it never busy-loops the doorbell.

**Idempotency:** explicit `idempotencyKey` wins (bounded); otherwise a content hash of `(sessionId + message + kind + options)` — a naive network retry of the identical body dedupes to the **same `dialId`**; a distinct intentional ring, or a re-ring after the TTL window, gets a fresh `dialId`. Clients SHOULD retry network failures with the same key. **Intentional (minor, per 430770): the idempotency hash EXCLUDES `context`** — two rings with the same `(sessionId+message+kind+options)` but different `context` dedupe to one ring; `context` is best-effort ancillary, not part of ring identity.

**Box/CLI token (containment rule):** the box/CLI presents a **scoped, short-TTL Senti user-session token** minted OUTSIDE the box and injected as env; **min-scope `pocket:dial`**, absolute expiry, rate/total caps, fail-closed. **Provider keys NEVER enter a box** (standing rule) — the CLI holds only this dial token, and the voice-provider key stays server-side behind `/tts`.

**Release gates (machine/warden, not forge):** route stays **dark until sentinelayer-api #783** (membership) is merged/deployed/smoke-proven (known-member 200 + uniform nonmember 404); APNs **off by default** in terraform; physical-device evidence is a release gate.

### `call-me` CLI (forge owns)
```
sl call-me --session <id> --kind decisionYours --message "<need>" [--option A --option B] [--gateway URL] [--json]
```
- Reads `SENTI_GATEWAY_URL` + `SENTI_DIAL_TOKEN` from env → works from the **microVM, a vscode terminal, CI, anywhere** with a shell + egress. Zero provider secrets in the box.
- Thin client over `POST /dial/ring-owner`; prints `dialId` and exits 0 on 200; surfaces the gateway error + non-zero exit otherwise; retries network with a stable `idempotencyKey`.
- **Same capability = an MCP tool `call_me`** so non-Claude agents (ChatGPT-web) can fire it. (Handler already anticipates "`sl ring-owner` / an agent's MCP tool".)

---

## 2. Who-hears-what routing surface (Gemma worker) — POLICY AS DATA

Per bundle: **policy is DATA-in, not code**, so B3 (`respawn.meeting/1` receipt-family, parked) bolts on cleanly. The Gemma worker consumes a `RoutingPolicy` and emits `RoutingDecision`s; it hardcodes no who-hears-what.

**Per-turn input:**
```json
{ "roomId":"…", "speaker":{"id":"…","kind":"human|agent"}, "ts":"…",
  "transcript":"…", "addressedTo":["id"], "topic":"…", "floorState":"…" }
```

**`RoutingPolicy` (the data the worker is configured by):**
```json
{
  "members": [{ "id":"claude-forge", "kind":"agent", "lanes":["voice"], "hearMode":"all|addressed|lane-match|none" }],
  "floor":   { "mode":"round-robin|open|moderated", "graceMs":800 },
  "transcribe": { "provider":"gemma-edge", "diarize":true, "minConfidence":0.6 },
  "route":   { "rules":[ { "when":{ "addressedTo|laneMatch|topic":"…" }, "to":["id"], "as":"text|summary" } ] },
  "budget":  { "maxTokensPerTurnPerAgent":512, "summarizeOverChars":1200 }
}
```

**`RoutingDecision` (emitted per turn):**
```json
{ "turnId":"…", "transcript":"…",
  "policyVersion":"1", "policyHash":"<sha256 of the RoutingPolicy that produced this>",
  "deliveries":[{ "to":"id", "payload":"text|summary", "reason":"addressed|lane|topic" }],
  "dropped":[{ "to":"id", "reason":"hearMode:none|budget|below-confidence" }] }
```
**`policyVersion` + `policyHash` are REQUIRED (AMEND-3):** a future B3 receipt over a decision must pin WHICH policy produced it, or the audit layer cannot attach without rewriting history. One cheap field now buys the whole B3 seam. (Content-addressed `turnId` joins the engram discipline in a later rev; not required now.)

**Gemma's job (cheap edge first pass):** VAD → diarize → transcribe → evaluate the policy rules → produce `deliveries`. **Only the matched slice reaches an agent's expensive model** — that is the token/inference-efficiency lever. Reverse path: an agent's text → TTS track published to the room.

**ENGRAM seam (bundle's lane):** each turn's transcript → an evidence-grade Observation, so agents get **hydrated context, not raw audio**; the B3 receipt-family attaches to `RoutingDecision` when warden un-parks it. Voice works WITHOUT receipts; the audit layer is additive.

---

## 3. Media plane (already decided — reference only, not re-opened)

**Cloudflare Realtime SFU + SQLite Durable Objects** ($0/mo verified); LiveKit as fallback; media never touches the DO. Every surface (phone/web/CLI/MCP) connects a WebRTC track; a headless agent **publishes a TTS track + consumes room audio via STT**. Standups = the same room + the §2 floor policy.

---

## Sequence (bundle's ruling)
1. This doc → shape-confirmed by machine (transport half) + bundle (contract shape). ← **you are here**
2. Build `call-me` CLI against §1 (demoable from any shell; live ring lights up when machine/warden deploy the gateway + `.p8` + #783).
3. `join-space` client + Gemma routing worker (§2) — after bundle slices; policy-as-data from day one.

Builds **behind the sprint pin** (invite/docs/billing); every PR two-key via warden; this slice is a proposal for warden's lane-pick (Carter 430426).
