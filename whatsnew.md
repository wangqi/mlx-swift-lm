# mlx-swift-lm Upgrade — `tag-20260616` → `tag-20260621`

**Merged:** 2026-06-21
**Upstream base:** `ml-explore/mlx-swift-lm` main (PRs #305, #310, #314, #318, #323, #327, #340, #344, #349, #354, #356, #359)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

This range brings **13 commits** (12 upstream PRs + our merge commit). The headline item for us is the upstream chunked-prefill rework (#344), which now overlaps the iOS-only chunking patches our fork already carried — that overlap produced the merge conflicts in the seven `MLXVLM/Models/*.swift` files we resolved.

---

## Highlights

### On-device / iOS memory & stability
- **VLM chunked prefill now honors `windowSize` on the native path (#344).** Single-pass VLM prefill allocated transient buffers proportional to prompt length; chunking to `windowSize` (default 512) cuts peak memory from **~17.7 GB → ~5.1 GB** on an 8k-token Gemma 4 prompt. Extended to `FastVLM`, `Gemma3`, `Qwen2VL`, `LFM2VL` (embed-only path) and `Pixtral`, `Mistral3` (inputIds + inputsEmbeds path). This is the same problem our fork already solved on iOS via `chunkedVLMPrefill`; both now coexist (see Risk R1).
- **iOS build fix (#356).** `homeDirectoryForCurrentUser` is `API_UNAVAILABLE` on iOS and broke the `IntegrationTestHelpers` SPM library. Hugging Face cache path resolution is centralized into `hfCacheDir()` / `hfSnapshotDir(modelId:revision:)`. Restores iOS buildability of the test helper target.
- **Speculative decoding memory gating + telemetry (#314).** Adds observability for draft-model acceptance/throughput and **gates auxiliary-model speculation off under memory pressure** so it never hurts on constrained (iOS) devices. Foundation for edge-aware speculative decoding.

### New models
- **Gemma 4 12B unified (#327)** — unified vision/audio Gemma 4 variant.
- **Nemotron Labs Diffusion (#310)** — text-diffusion LLM architecture in `MLXLLM`.

### New capabilities / API
- **Swift model conversion API (#318)** — quantize safetensors-backed LLMs through `MLXLMCommon` + `LLMModelFactory` (`ModelConversion.swift`). On-device/desktop quantization without a Python round-trip.
- **`ModelTypeRegistry.contains(_:)` (#349)** — check whether the registry can instantiate a `model_type` *before* a throwing/allocating `createModel`. Lets us validate a Hub repo's architecture is runnable **before** a multi-GB download.

### Correctness fixes
- **Qwen3.5 recurrent cache handling (#323)** — GatedDelta convolution state stored contiguously and array-cache metadata advanced after each recurrent step, matching upstream mlx-lm for Qwen3.5 / Qwen3-Next; left-padding masks kept active post-init; Qwen3 RoPE setup aligned with the shared initializer.
- **nomic-embed-text-v1.5 (#305)** — fixes `Key embeddings.position_embeddings.weight not found` load failure.

### Build / toolchain
- **Xcode 16.3 / SDK < 26 build fix (#359)** — `context` declared `nonisolated(unsafe)` on SDK < 26 so it compiles under Swift strict concurrency.
- **swift-syntax floor raised to 602.0.0 (#340)** — keeps consumers on swift.org's signed prebuilt swift-syntax artifacts; below 602 silently falls back to compiling from source (~200 build tasks).

### Tests
- **Speculative decoding test oracle fixed (#354)** — deterministic high-margin transition model for exact speculative-vs-greedy equality; Gemma3 kept as a smoke test.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| VLM long-prompt prefill | Lower peak memory on the native path too (#344); our iOS `chunkedVLMPrefill` retained |
| Speculative decoding | Auto-disabled under memory pressure (#314) — safer on device |
| Test helper target | Now builds on iOS again (#356) |
| Pre-download arch check | `ModelTypeRegistry.contains(_:)` avoids wasted multi-GB downloads (#349) |
| Qwen3.5 / Qwen3-Next | More correct recurrent decoding (#323) |

---

## Risk Assessment — **7 identified risks** (2 medium, 5 low)

### R1 — Overlapping chunked-prefill paths (MEDIUM)
Upstream #344 added windowSize chunking to the **native (macOS)** branch of six VLM models, while our fork already chunks the **iOS** branch via `chunkedVLMPrefill`. The merge kept our iOS path and adopted upstream's native loop, so both platforms now chunk. *Verify:* both branches compile and the seven resolved files (`FastVLM`, `Gemma3`, `LFM2VL`, `Mistral3`, `Pixtral`, `Qwen2VL`, `Qwen35`) produce correct logits on device and on macOS. Long-prompt regression coverage: `testcases/ai/mlx/MLXVLMLongPromptTests.swift`.

### R2 — Qwen35 M-RoPE state handoff change (MEDIUM)
Upstream wraps the native Qwen35 path in `withPreparedCache(...)` and passes `state: nil` (PR #283 lineage), whereas our `helper/docs/mlx-swift.md` documents passing `preparedState` on the macOS single-shot path. Our iOS path still passes `preparedState` through `chunkedVLMPrefill`. *Verify:* Qwen3.5 VLM image positions remain correct on macOS (no degradation to text-only sequential positions). The `canSlicePrecomputed` guard documented in mlx-swift.md must still hold for chunks 2+.

### R3 — swift-syntax floor bump to 602.0.0 (LOW)
A consumer pinned below 602 will now fail to resolve or rebuild swift-syntax from source. *Mitigation:* confirm the app's package graph resolves swift-syntax ≥ 602 with the current toolchain.

### R4 — Xcode 16.3 / SDK < 26 concurrency change (LOW)
`nonisolated(unsafe)` is a deliberate strict-concurrency escape hatch on old SDKs; no effect on our SDK 26 builds but worth noting if a CI runner uses an older SDK.

### R5 — New architectures unverified on device (LOW)
Gemma 4 12B unified (#327) and Nemotron Labs Diffusion (#310) are additive in the factories but untested on iOS memory budgets. 12B is likely too large for most iOS devices; the diffusion LLM decoding path is new. *Mitigation:* only expose via `models_*.json` after on-device validation.

### R6 — Model conversion API surface (LOW)
New `ModelConversion.swift` adds public API we don't yet call. Low risk unless we adopt it; quantization is memory-heavy and not suited to iOS.

### R7 — Embedding/cache fixes change numerics (LOW)
nomic-embed (#305) and Qwen3.5 recurrent cache (#323) alter load/decode behavior. Re-run embedding and Qwen3.5 smoke tests to confirm no downstream regression.

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`) to confirm the merged VLM files compile.
2. Run `testcases/ai/mlx/MLXVLMLongPromptTests.swift` on a device for R1/R2.
3. Decide whether to surface Gemma 4 12B unified / Nemotron Diffusion in `models_*.json`.
4. Update `helper/docs/mlx-swift.md` "Models currently patched" note now that native paths also chunk.
