# PocketInference

On-device, evidence-bounded checkpoint Q&A using LiteRT-LM. The package never exposes model tools and creates a fresh conversation for every question so evidence from one checkpoint cannot leak into the next.

## Dependency

- LiteRT-LM: exact Swift package version `0.13.0`
- Swift product: `LiteRTLM`
- Model input: a local, integrity-verified `.litertlm` file

The deployment manifest must supply the expected model SHA-256 and byte count through `ModelDescriptor`. `ModelArtifactStore` installs only an exact size/digest match, cancels downloads that exceed the descriptor, uses an ephemeral no-cookie session, rejects redirects/non-HTTPS URLs/embedded credentials, and excludes the installed model from device backup. Only the store can issue `VerifiedModelArtifact`. Before initialization, the engine materializes a private runtime snapshot using an APFS copy-on-write clone when available and a bounded streaming copy otherwise, then verifies the exact snapshot bytes and makes the file read-only. LiteRT-LM initialization and benchmarking use that unexposed snapshot rather than reopening the caller-visible installed path.

## Integration

```swift
let descriptor = try ModelDescriptor(
    identifier: "gemma-4-e2b-it",
    fileName: "gemma-4-e2b-it.litertlm",
    sha256: deploymentSHA256,
    byteCount: deploymentByteCount
)
let store = ModelArtifactStore(
    rootDirectory: modelDirectory,
    allowedDownloadHosts: ["models.example.com"]
)
let artifact = try await store.verifyInstalledModel(descriptor)
let engine = LiteRTLMInferenceEngine(
    modelIdentifier: descriptor.identifier,
    cacheDirectory: cacheDirectory
)
let loadMetrics = try await engine.prepareModel(artifact)
let result = try await engine.answer(
    GroundedInferenceRequest(bundle: bundle, question: question)
)
```

`GroundedPromptBuilder` caps the encoded prompt at 7,000 UTF-8 bytes by default and reports the exact evidence IDs admitted after truncation. `GroundedAnswerDecoder` accepts only an `answer` plus known, unique IDs from that admitted set. An uncited answer must equal `I do not have evidence for that.` exactly. Any extra model output field is rejected. The default 8,192-token engine budget reserves at least 1,024 tokens beyond the byte-bounded prompt.

## Measurement Contract

- `loadMilliseconds`: exact-byte runtime snapshot verification, initialization, and conversation-config validation.
- `timeToFirstTokenMilliseconds`: invocation to the first LiteRT-LM message chunk.
- `totalMilliseconds`: invocation through strict JSON/citation validation.
- `residentMemoryBytes`: process resident memory sampled after the operation.
- `thermalState`: `ProcessInfo.thermalState` sampled after the operation.
- `benchmark`: LiteRT-LM's experimental prefill/decode benchmark, labeled with device, OS, model, and backend.

These are software timestamps, not external power or acoustic measurements. Do not publish target-phone performance until `DeviceBenchmarkReport` is captured on that phone.

## Cancellation

Task cancellation, Stop, and barge-in call `cancel()`, which invalidates the current generation before invoking LiteRT-LM cancellation. A newer answer supersedes any in-flight or pending answer. Error cleanup cannot leave a run marked active.

## Verification

Run on a Mac with the current Xcode toolchain:

```bash
cd packages/PocketInference
swift test
```

Then run `benchmark(prefillTokens:decodeTokens:)` on the physical demo phone. This package was authored on a Windows host without Swift/Xcode, so a source-parser pass is not a substitute for that build and device gate.
