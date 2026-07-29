# Voice-control outbox slice

Base: `d793b2f390e91096945923d9a6703edd90d4935d`

## Plan

- [x] Preserve the reviewed command-ledger head in its existing worktree.
- [x] Verify current Cloudflare alarm, Queue, test-helper, Workers type, and Wrangler schema surfaces.
- [x] Ask Forge to challenge the topology before implementation.
- [x] Commit a moderation command, outbox row, revision CAS, and recovery alarm atomically.
- [x] Dispatch bounded, opaque, stable command envelopes from a pre-armed alarm.
- [x] Consume Queue messages with per-command leases and terminal dedupe outside the room coordinator.
- [x] Keep the only executor unavailable, zero-I/O, and structurally unable to report provider success.
- [x] Configure an at-least-once Queue consumer and DLQ without creating or deploying resources.
- [x] Prove acceptance replay, crash-window resend, duplicate delivery, explicit ack/retry, terminal reconciliation, and no provider I/O.
- [x] Update the normative contract, ADR, README, and lessons.
- [x] Run generated types, strict TypeScript, all Worker tests, Wrangler dry-run, and staged SentinelLayer review.
- [ ] Commit, push the exact SHA, unlock files, and obtain Forge's independent verdict.

## Review

- `npm run check`: generated bindings, strict TypeScript, 30/30 workerd tests,
  and Wrangler dry-run green.
- SentinelLayer staged deterministic review
  `review-20260729-103828-e4be0d21`: 15 files, normative contract supplied,
  refreshed ingest, zero findings.
- Independent exact-SHA Forge/Claude review remains pending before handoff.
