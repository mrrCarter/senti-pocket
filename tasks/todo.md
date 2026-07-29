# Sharded admission ledger kernel

Base: `d31b8f56f0850edc5cceea8063a9a1f2dfb22d69`

## Plan

- [x] Preserve the roster candidate in its own clean worktree.
- [x] Record the proposed admission boundary for Forge architecture challenge.
- [x] Define 64 deterministic room admission shards from server HMAC keys.
- [x] Implement room priming, exact identity matching, and revision floors.
- [x] Implement fenced create/refresh/update admission reservations.
- [x] Fail closed into reconciliation on uncertain or expired provider work.
- [x] Partition the room admission budget exactly across all 64 shards.
- [x] Add hostile workerd tests for identity, fences, quota, and crash recovery.
- [x] Document composition, migration, and remaining scale gates honestly.
- [x] Run generated types, strict TypeScript, workerd tests, and Wrangler dry-run.
- [x] Run a deterministic staged SentinelLayer review.
- [ ] Push one immutable candidate and obtain Forge CODE+DOCS verdict.

## Honest gates

- This atom adds an uncomposed Durable Object class and does not reroute the
  production join endpoint.
- Provider calls, tokens, Cloudflare resources, deployment, PR, merge, and
  activation remain untouched.
- The existing RoomGovernor admission and webhook paths remain the current
  runtime. No 5k/10k, provider capacity, or latency claim is made.
- Forge's connected Claude Code host remains live but quota-limited until its
  reported 2026-08-01 01:00 America/New_York reset. Review is queued, not
  waived.

## Review

- `npm run check`: generated bindings, strict TypeScript, 61/61 workerd tests,
  and Wrangler 4.115 dry-run green.
- The Windows host has no Swift toolchain. The additive duplicate-provider-ID
  roster guard has authored XCTest coverage but remains Mac/iOS compile
  unproven.
- SentinelLayer staged review is rerun against the final staged candidate
  after every bookkeeping change; final run ID is recorded in the immutable
  handoff.
