# REMOVE observation-kernel slice

Base: `e8477a7fa61548222d89df1118b6bbbda81cb236`

## Plan

- [x] Preserve the reviewed outbox head in its existing worktree.
- [x] Verify RealtimeKit's signed peer identity and backend kick target surfaces.
- [x] Freeze the peer-generation fence and execution-side TOCTOU residual with Forge.
- [x] Add fresh execution-time authorization and peer-exact desired-state provider ports.
- [x] Pin signed provider session plus peer identity into REMOVE commands.
- [x] Add the durable attempt, observation, conflict, and three-field truth model.
- [x] Keep production composition on the unavailable zero-I/O executor.
- [x] Prove revoke-before-execute, stable crash retry, stale fence, peer mismatch,
  stale join/old leave ordering, exact signed observation, duplicate webhook,
  already absent, one nonterminal remove per peer, and timeout conflict.
- [x] Update the normative contract, ADR, README, and lessons.
- [x] Run generated types, strict TypeScript, all Worker tests, Wrangler dry-run,
  and staged SentinelLayer review.
- [ ] Commit and push the exact SHA, unlock files, and obtain Forge's independent
  CODE+DOCS verdict.

## Review

- `npm run check`: generated bindings, strict TypeScript, 43/43 workerd tests,
  and Wrangler dry-run green.
- SentinelLayer deterministic review
  `review-20260729-114438-49b5d7d0`: 14 staged files, normative contract
  supplied, refreshed ingest, P0/P1/P2/P3 = 0.
- Independent exact-SHA Forge/Claude review pending before handoff.
