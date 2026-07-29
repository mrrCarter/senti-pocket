# Server-authoritative roster identity slice

Base: `d856adfb682f625c2daab68b80e94ada20d6a4ef`

## Plan

- [x] Preserve the REMOVE observation-kernel exact head in its own worktree.
- [x] Trace the current iOS fail-closed remote identity boundary.
- [x] Define deterministic roster shards and an HMAC revision-vector cursor.
- [x] Project server admission bindings without provider IDs becoming
  principals.
- [x] Project only verified exact peer joins/leaves with delivery/digest
  dedupe and stale-generation protection.
- [x] Add authenticated bounded roster pages with final vector revalidation
  and explicit resync.
- [x] Add Swift atomic page staging with wrong-epoch, gap, duplicate-binding,
  and count-overclaim rejection.
- [x] Prove the Worker kernel with strict TypeScript and 50/50 workerd tests.
- [x] Run generated types, strict TypeScript, 50/50 workerd tests, and Wrangler
  dry-run.
- [x] Run the deterministic staged SentinelLayer review.
- [ ] Obtain Forge CODE+DOCS and Mac/iOS compile verdict on an exact pushed
  revision.

## Honest gates

- Production composition, Cloudflare resources, provider calls, secrets,
  deployment, PR, merge, and activation remain untouched.
- The roster read model is sharded, but room admission and initial signed
  delivery acceptance still touch the RoomGovernor. No 5k/10k or provider
  capacity claim is made.
- The Swift files are uncomposed package code. This Windows host has no Swift
  toolchain; Forge's Mac/iOS compile and physical-device receipts remain
  required.
- Forge's connected Claude Code host reached its weekly usage limit on
  2026-07-29 and reported a reset at 2026-08-01 01:00 America/New_York.
  Independent review remains pending; this is not a review waiver.

## Review

- `npm run check`: generated bindings, strict TypeScript, 50/50 workerd tests,
  and Wrangler dry-run green.
- SentinelLayer staged review `review-20260729-123447-447b36ee`: 19 files,
  refreshed ingest, normative contract supplied, P0/P1/P2/P3 = 0.
- Swift/Mac compile and independent exact-revision Forge review remain pending.
