# PocketVoice

Offline speech recognition, duplex capture, deterministic barge-in, and pluggable speech synthesis for Senti Pocket.

## Pinned Artifacts

- whisper.cpp XCFramework: `v1.9.1`
- SwiftPM artifact SHA-256: `8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c`
- `ggml-base.en.bin` byte count: `147964211`
- `ggml-base.en.bin` SHA-256: `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`

`WhisperCPPRecognizer.prepareModel` verifies the full file before loading it. Transcription accepts only finite 16 kHz mono PCM from 0.1 through 30 seconds and uses whisper.cpp's abort callback for cancellation.

## Voice Loop

1. `MicrophoneCapture` configures duplex voice-chat audio and emits bounded Float32 mono frames.
2. `EnergyVoiceActivityDetector` applies fixed RMS hysteresis plus attack/release durations.
3. A `speechStarted` transition calls `DeterministicBargeInController`, which moves out of the armed state before concurrently stopping speech and inference. Duplicate events are idempotent.
4. `CapturedAudioAccumulator` and `PCMResampler` produce the 16 kHz request consumed by whisper.cpp.
5. `HybridSpeechSynthesizer` uses the gateway premium path only when online and falls back to `AVSpeechSynthesizer` otherwise.

Audio interruptions, media-service resets, and loss of the active input route terminate capture with an explicit error. They do not leave the app in a false listening state.

## Premium TTS Gateway

The phone never stores or sends an ElevenLabs API key. It POSTs an AIdenID-authorized request to one configured HTTPS gateway host:

```json
{
  "modelId": "eleven_flash_v2_5",
  "outputFormat": "pcm_24000",
  "text": "bounded narration",
  "tone": "neutral",
  "voiceId": "configured-voice"
}
```

The adapter refuses redirects and any request containing `xi-api-key`. A successful response must be raw little-endian signed 16-bit mono 24 kHz PCM with:

```text
X-Senti-Audio-Format: pcm_s16le_24000
```

The stream is capped at 24 MB. PocketContracts' `BriefingTone` is the single constrained vocabulary used by the bundle, phone, and gateway; checkpoint text is never forwarded as a provider-control prompt.

## Measurement Contract

- AVSpeech first-audio value: `AVSpeechSynthesizerDelegate.didStart`, labeled `avSpeechDidStartCallback`.
- Premium first-audio value: first decoded PCM buffer scheduled to `AVAudioPlayerNode`, labeled `pcmFirstBufferScheduled`.
- Neither value is an acoustic loopback measurement. Measure actual speaker onset separately on the target phone before advertising TTFA.
- Whisper reports audio duration, transcription wall time, real-time factor, resident memory, and thermal state.
- `SpeechBenchmarkHarness` reports per-command word error rate and emits a device-labeled JSON-ready report.

## Physical Gate

On the exact demo phone, run five consecutive cycles:

1. model load and schema-valid local answer;
2. record and transcribe a known command;
3. speak with AVSpeech offline;
4. interrupt with human speech and with Stop;
5. verify no uncontrolled speech, stale listening state, or deadlock.

Capture model/device/OS, load time, TTFT, transcription real-time factor, WER, memory, thermal state, synthesis measurement kind, and interruption latency for every run. This package was authored on a Windows host without Swift/Xcode or a connected iPhone; physical results remain unvalidated until that evidence exists.
