# PocketSyncClient

Owner: **claude-pocket-relay**. Narrow interface — pull bounded, signed `PocketBundle`s to the
phone and track sync state so briefing playback survives offline. The phone holds **no** Senti
credentials; the gateway authenticates and hands down bundles only.

- `PocketSyncClient` protocol: `pullBundles(since:)`, `fetchBundle(id:)`, `syncState()`.
- Implementations MUST be idempotent — re-pulling a cached bundle returns it unchanged (dedup by `bundleId`).
- Types are **INTERIM**; replace with `import PocketContracts` (Atlas v0.1) at freeze.

Build/test on the Mac (no Swift toolchain on the relay box): `swift test`.
