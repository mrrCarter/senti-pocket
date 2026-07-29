# Admission invariant hardening

Parent: `9be3c567c599af068b8250c08a5042f3bc0a4674`

## Plan

- [x] Preserve immutable admission candidate `9be3c567` in its clean worktree.
- [x] Audit quota, identity, restart, and concurrency claims against the code.
- [x] Correct the Senti plan and lock one isolated child worktree.
- [x] Require exact canonical UTC instants before deriving daily quota buckets.
- [x] Pin the room-wide daily admission maximum at room prime.
- [x] Verify every principal maps to its server-derived participant key.
- [x] Enforce room-wide provider participant identity ownership across shards.
- [x] Add hostile rollover, config-change, concurrency, and eviction proofs.
- [x] Cover reconciled refresh/update restoration and same-page Swift aliasing.
- [x] Update architecture, contract, service, and lesson documentation honestly.
- [x] Run generated types, strict TypeScript, workerd tests, and Wrangler dry-run.
- [x] Run deterministic SentinelLayer review and an independent elegance pass.
- [ ] Freeze/push one exact candidate and obtain Warden/Forge CODE+DOCS verdict.

## Honest gates

- This atom adds an uncomposed Durable Object class and does not reroute the
  production join endpoint.
- Room-wide provider-ID claims are durable tombstones. A claim may safely
  outlive a failed local completion, but it is never released or reassigned to
  a different principal. Pinned conflict/capacity/end-race rows may remain
  reconciling until an authoritative recovery or epoch disposal path handles
  them.
- Legacy admission objects without a pinned maximum require explicit
  migration or recreation before composition; the kernel will not infer one.
- `IDENTITY_HMAC_SECRET` must remain stable for live/reconciling room epochs.
  Rotation requires epoch rollover or a separately reviewed dual-key migration.
- Provider calls, tokens, Cloudflare resources, deployment, PR, merge, and
  activation remain untouched.
- The existing RoomGovernor admission and webhook paths remain the current
  runtime. No 5k/10k, provider capacity, or latency claim is made.
- Forge's connected Claude Code host remains live but quota-limited until its
  reported 2026-08-01 01:00 America/New_York reset. Review is queued, not
  waived.

## Review

- Baseline `9be3c567`: generated bindings, strict TypeScript, 61/61 workerd
  tests, and Wrangler 4.115 dry-run green.
- Final working tree: targeted admission/identity suites 29/29 and full workerd
  suite 79/79; generated binding check, strict TypeScript, and Wrangler 4.115
  dry-run green.
- Independent distributed-code review and independent test/docs review both
  returned `+1` with activation gates retained above.
- SentinelLayer diff review scanned 15 files with 0 P1 and 0 P2 findings.
- The Windows host has no Swift toolchain. The additive duplicate-provider-ID
  roster guards may receive authored XCTest coverage but remain Mac/iOS compile
  unproven until Forge supplies a Mac receipt.
- Warden and Forge silence is not approval. The exact final SHA remains frozen
  after handoff; any review fix lands in a new child commit.
