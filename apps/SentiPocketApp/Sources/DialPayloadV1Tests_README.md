# Dial payload decoder contract

The executable decoder coverage lives in
`apps/SentiPocketApp/Tests/DialPayloadV1KAVTests.swift`. It reads the gateway's committed
`services/pocket-gateway/test/fixtures/dial-payload-v1.json` directly, so producer and consumer share one fixture.

The client independently enforces the gateway's security policy:

- `go`, `decisionYours`, and `pickOption` are write kinds and must use `fetch=true`; a contradictory RICH push is rejected.
- `info` and `checkpointReady` are the only kinds eligible for `fetch=false` direct rendering.
- Unknown kinds are rejected for both fetch shapes, so a future write kind cannot silently inherit RICH authority.
- RICH display kinds require a nonempty message and cannot carry options.
- LEAN pushes always require authenticated hydration, even if the push contains stray governed fields.

Registry V2 keeps the same content policy after its nested binding-fence admission. The app test target exercises the
legacy shared fixture and the production V2 shape.
