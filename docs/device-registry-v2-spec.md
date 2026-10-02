# Senti Pocket Device Registry V2

Status: implementation checkpoint, pending macOS/Xcode execution and deployment review.

## Goal

Route a Senti VoIP ring to the currently authorized physical app installation without allowing a delayed registration,
logout, token rotation, session switch, process crash, Lambda retry, or Dynamo TTL delay to resurrect older authority.
The design must remain bounded per target and safe across concurrent gateway instances.

## Non-goals

- This registry does not authorize or author Senti session content.
- It does not replace authenticated session membership checks on `/dial`, `/dial/register`, or hydration.
- It does not provide the APNs provider credential or prove physical delivery.
- Registry V1 is compatibility-only and never receives or satisfies a V2 proof.

## Device identity and generation

- One random 32-byte base64url `installationId` and its canonical decimal uint64 generation live in one
  `AfterFirstUnlockThisDeviceOnly` Keychain record.
- Registration, revocation, token rotation, principal change, and selected-session change serialize through that record.
- A pending transition is persisted before network I/O. An exact retry reuses it.
- Identical lease renewal may reuse a completed generation. A changed binding advances generation.
- Generation gaps are valid. Lower generations never replace a higher durable server head.
- If the Keychain item is missing, the app creates a new installation ID. It never reuses an old ID at generation 1.
- At uint64 exhaustion, the app persists a cleared new identity and does not construct a compare-delete for the old ID.

## Register contract

`POST /dial/register` authenticates the bearer, derives `humanId` and the full issuer/site/pairwise principal
server-side, verifies human-ID membership in `sessionId`, and accepts:

```json
{
  "registryVersion": 2,
  "installationId": "<base64url>",
  "installationGeneration": "<positive uint64 decimal string>",
  "voipToken": "<PushKit token>",
  "sessionId": "<authorized session>",
  "platform": "apns"
}
```

For a new higher generation, the server creates opaque `bindingId` and `bindingRevision`. The same generation and
canonical binding digest is an idempotent retry and returns the same proof. The same generation with different
authority returns `binding-generation-conflict`; a lower generation returns `binding-superseded`; a full target returns
`device-cap-reached`; a token owned by a different live installation returns `device-token-claimed`. iOS may perform
one forced-generation retry only for the first two typed reasons.

The success response binds the exact session, platform, generation, proof, and future lease expiry. iOS validates and
atomically commits it only while the initiating bearer, token, selection, and registrar operation are still current.

## Unregister contract

`POST /dial/unregister` requires a newly advanced generation plus the prior exact proof. It remains available after
membership loss so an authenticated former member can revoke its own binding. The server advances the durable head to
a tombstone before best-effort lease/index deletion. Stale and repeated cleanup is idempotent and non-oracular.

The app clears its accepted proof in the same Keychain update that persists the pending unregister. A failed cleanup
request remains retryable across process restarts.

Index cleanup runs only after the request creates or observes its exact tombstone. A delayed unregister at the same
generation as an in-flight register is idempotent and cannot erase that register's candidate between head installation
and token-claim activation.

## Durable gateway model

- Installation head: durable, HMAC-keyed, no Dynamo TTL; contains generation high-water mark, operation, target/token
  digests, and opaque proof.
- Preparation: one CAS-versioned, short logical reservation per installation. It fixes the future proof before any
  authoritative head change and makes exact crash retries reuse the same server IDs.
- Lease: generation-specific and expiring; contains the raw APNs token required for delivery.
- Target index: bounded active-or-reserved candidate hashes with exact record-version CAS. It is never authoritative.
- Token claim: one global CAS record per HMAC(platform, APNs topic/environment, token), with separate active and pending
  owners. A different live installation cannot claim it. The durable empty/released record is also the token's V2
  migration fence.

Registration reserves target capacity and token ownership before writing a generation-specific lease or advancing the
head. Thus capacity, duplicate-token, and reservation-contention failures leave the prior head and raw-token lease
unchanged. A synchronous token-claim loser conditionally removes only its exact earlier target reservation while
preserving an active same-installation binding or any different live preparation record, including a same-generation
sibling retry. Head advancement uses a Dynamo conditional put over a
fixed-width 20-digit generation ordering. Token
activation occurs after the prepared head lands; a crash in between is fail-closed and an exact retry completes it.
Lookup accepts an index candidate only when current head, exact unexpired lease, and active token claim agree. Dispatch
revalidates immediately before send; the app’s exact proof comparison is the final lookup-to-delivery race fence.

Raw installation, principal, human, and session identifiers never appear in V2 keys. HMAC domains separate
installation, target, scoped token, binding, and tombstone derivations. The HMAC key is at least 32 bytes.
`DIAL_REGISTRY_TOKEN_SCOPE` identifies the APNs topic/environment. Either value requires an explicit migration to
rotate.

## iOS authorization gates

- A partial proof is malformed. A V1/absent proof cannot masquerade as V2.
- CallKit reports every VoIP push as required by iOS, but unauthorized pushes use generic metadata and retain no
  actionable hydration state.
- The exact selected session and binding proof are checked at receive, before and after authenticated hydration, before
  starting the governed dial, and on every governed-write authorization check.
- Authentication, selection, PushKit-token, or binding loss synchronously clears the live gate and cancels active calls.
- Same-session principal/binding ABA must not revive a previously hydrated flow.

## Migration and operations

`DIAL_REGISTRY_HMAC_KEY` enables V2 and requires `DIAL_REGISTRY_TOKEN_SCOPE`. During migration, V1 read/write can
remain explicit, but a token that has acquired any V2 claim never falls back to its V1 row. A different legacy-device
token can remain during the grace window. New V1 rows use and carry the exact full-principal namespace; historical
human-only rows are intentionally unreadable because their originating site cannot be proven. After supported devices
renew:

```text
DIAL_REGISTRY_V2_REQUIRED=1
DIAL_REGISTRY_TOKEN_SCOPE=com.plexaura.sentipocket.app:development
DIAL_REGISTRY_ALLOW_V1=0
DIAL_REGISTRY_READ_V1=0
```

No deploy occurs from this checkpoint. The gateway suite, deterministic review, and independent concurrency review must
pass first. Swift compilation, hosted app tests, signed archive, and IPA export require macOS/Xcode.

## Acceptance criteria

1. Same-generation exact retry preserves the server proof; same-generation changed authority conflicts.
2. A delayed lower-generation register cannot overwrite a completed rebind or unregister tombstone.
3. Logical lease expiry rejects a record even while Dynamo has not physically deleted it.
4. A stale unregister cannot delete a newer or equal-generation in-flight same-installation binding/index candidate.
5. Lookup-to-send rebind races produce no actionable old push.
6. Same human/session identifiers under different full principals never share V1 or V2 devices or generated dial
   identity; untagged historical V1 rows fail closed.
7. Target-cap and duplicate-token losers change no prior head and persist no raw-token lease; concurrent last-slot
   contenders have exactly one winner, and a synchronous token-claim loser releases only its exact target reservation
   without erasing a same-generation sibling.
8. A matching V1 token cannot reappear after V2 registration/unregister, while a distinct legacy device can remain
   during grace.
9. Target candidate storage and delivery fan-out are bounded.
10. iOS rejects V1, partial, expired, wrong-revision, and wrong-generation proofs.
11. Pending register, unregister, and non-authorizing revocation proof survive restart; corrupt state fails closed.
12. Same-session A → nil → B authorization ABA yields zero governed-write requests and no outbox intent.
13. The signed IPA manifest proves the source commit/tree, configured bundle ID, actual Developer Team ID,
    application identifier, APNs environment, Release origins, SHA-256, and an unexpired matching provisioning-profile
    class/device shape without storing Apple credentials.
