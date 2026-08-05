# Operation-admission Lambda artifact

This directory is the deployable Node 22 entrypoint for the two protected Registry V2 routes. It does not activate
anything. `enabled = false` creates no stack resources. Provision the stack dark with `enabled = true`,
`traffic_enabled = false`, and `publish_dns = false`; keep public traffic off until live IAM and route-negative proofs
pass.

The handler reads `DEVICE_REGISTRY_HMAC_SECRET_ARN` with the exact
`DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID`. It never requests `AWSCURRENT` or falls back to a version stage. The returned
version must match the pin. The secret must be a `SecretString` containing canonical base64 that decodes to 32-1024
bytes; `SecretBinary`, non-canonical base64, and unbounded material are rejected. It then composes the
strict reusable-Senti admission app, a DynamoDB v3 adapter, and a synchronous gateway invoker that accepts only an
immutable numeric version ARN matching `GATEWAY_LAMBDA_VERSION`. It also requires AWS to return that exact
`ExecutedVersion`. Admission authenticates once, then attaches a 10-second exact-request assertion whose signed random
`jti` is atomically consumed by the private gateway's shared store. Non-protected routes fail closed here; they must use
their direct API-to-gateway integrations.

Build from this directory with Node 22 and npm:

```sh
npm ci
npm test
npm run package
```

`npm run package` bundles the exact locked production dependencies and emits unsigned source-verification artifacts:

- `dist/index.mjs` — the complete standalone bundle;
- `dist/operation-admission.zip` — a deterministic ZIP containing exactly `index.mjs` at its root.

The Terraform handler must remain `index.handler`. CI uses this ZIP only to prove reproducible source bytes; it does not
sign, upload, or deploy production code. For production, submit this exact unsigned ZIP to AWS Signer through the active
profile named by `admission_signing_profile_name`. Retain the source digest, signing job id, exact immutable profile-
version ARN, and signed destination bucket/key/VersionId. Configure Terraform with that immutable **signed** S3 object
and set `admission_package_sha256` to the canonical base64 encoding of the signed ZIP's raw SHA-256 bytes. A hexadecimal
`sha256sum`/`Get-FileHash` result is useful retained evidence, but it is not the Terraform input. The module creates an
`Enforce` code-signing configuration that trusts only the resolved profile version for every enabled production
deployment, including dark provisioning; the unsigned CI ZIP is not a production deployment object.

The packager fixes the unsigned ZIP entry timestamp and permissions, so identical source, lockfile, Node, npm, and
esbuild versions produce the same source bytes. `gateway_release_artifact_sha256` is separate, independently supplied
evidence for the existing gateway version; runtime attestation does not self-report its control-plane code digest.
