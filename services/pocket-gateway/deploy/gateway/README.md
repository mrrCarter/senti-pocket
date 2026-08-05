# Dark Pocket gateway Lambda artifact

This directory is the deployable Node 22 entrypoint for the private Pocket gateway. It turns the transport from PR #131
into an executable, reviewable Lambda artifact without making it public.

The first artifact is deliberately fail-safe:

- `APNS_VOIP_ENABLED` is absent/`0` by default. That path neither validates nor reads the APNs secret and injects no
  `apnsSend`, so `/dial` retains its honest `501` behavior.
- Production `createLambda` constructs the authoritative, role-aware target-membership resolver from the injected
  `fetch` boundary and fixed `SENTI_API_BASE_URL`; bootstrap exposes no legacy/static membership-adapter seam. Keep the
  artifact release-dark until API PR #783 is merged and deployed, then prove the membership endpoint returns `200` for
  a known member and the same opaque `404` for a nonmember. An empty list, demo room, environment allowlist, or
  caller-supplied session id is not an acceptable substitute.
- Receipt-signing, Registry V2 HMAC, and optional APNs `.p8` material are each read by complete secret ARN plus immutable
  `VersionId`. No `AWSCURRENT` fallback or `SecretBinary` input is accepted.
- APNs key bytes never enter Lambda environment variables, Terraform state, logs, metrics, errors, CI artifacts, or
  Senti. The parsed private P-256 `KeyObject` is passed only to the existing native APNs transport.

Build with the reviewed Node/npm versions:

```sh
npm ci
npm test
npm run package
```

`npm run package` emits `dist/index.mjs` and a deterministic unsigned source artifact, `dist/gateway.zip`, containing
exactly `index.mjs`. CI verifies reproducibility only; it does not upload, sign, or deploy. Production requires AWS
Signer, an immutable signed S3 `VersionId`, and the matching canonical base64 SHA-256 input to Terraform.

The sibling `infra/terraform/gateway` module can publish one numeric Lambda version. It intentionally creates no API
Gateway route, Lambda URL, alias, DNS record, or permission for public invocation. Rollback remains a later mapping back
to an earlier reviewed numeric version, or leaving APNs disabled.
