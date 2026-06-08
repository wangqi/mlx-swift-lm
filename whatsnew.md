# mlx-swift-lm Upgrade: tag-20260425 → tag-20260607

**Date:** 2026-06-07
**Range:** `tag-20260425..tag-20260607` (56 commits)
**Baseline previously integrated in app:** tag-20260522 (`08c940d`)
**App integration point:** `ai/AIChatModelMLX.swift`, docs in `helper/docs/mlx-swift.md`

This upgrade folds two upstream merges into our fork. The first (`0622987`/`08c940d`)
brought the tag-20260522 audio/Gemma4/MoE work already documented in
`LocalModelEngineInfo.mlxSwiftInfo`. The second merge (`3496df0`, this upgrade)
brings the tag-20260607 delta on top of it, resolving six conflicts across our
locally-patched tool-call and VLM-prefill files.

---

## New Capabilities

- **Audio resources as model input (#298).** `UserInput` and `LMInput` now carry
  audio alongside images and video; `Chat.Message` gains an `audios:` parameter
  (default `[]`, non-breaking). Lays groundwork for audio-in VLM/omni models.
- **Runtime LoRA toggle + PEFT adapter loader (#316).** Enable/disable LoRA at
  runtime and load PEFT-format adapters without rebuilding the container.
- **Structured ChatSession continuation (#313).** Resume a `ChatSession` with
  structured state for multi-turn flows.
- **ParoQuant pairwise-rotation quantization (#164).** Loads AutoAWQ-format
  PARO-quantized models, applying pairwise Givens rotation at runtime via a Metal
  kernel (`RotateQuantizedLinear`); rotation state derived once at load time and
  thread-safe under concurrent inference. Adds a new on-device quantization format.

## VLM Correctness & Speed (iOS-relevant)

- **Qwen2.5-VL MROPE / rope_deltas / invFreq fixes (#239, #238).** Matches Python
  mlx-vlm parity; MROPE state now threaded through `LMOutput.State` for concurrent
  session safety; vision-encoder attention mask is no longer ignored.
- **SmolVLM2 small-image upscaling fix (#208/#255).** `tiles()` no longer upscales
  images smaller than the processing budget — ~9x faster on small images (512×384:
  1 patch/147 tokens instead of 13 patches/1140 tokens).
- **Idefics3 SigLIP dtype fix (#296).** Vision encoder runs SigLIP in float32 rather
  than bf16, fixing numerical drift.
- **Qwen2-VL chat template (#242).** Emits vision tokens before text, matching the
  reference template.
- **Qwen3.5 VLM sanitize for bare `model.*` weight keys (#143/#254).**

## Gemma 4 / MoE

- **Gemma4 quantized KV-cache attention fix (#237).**
- **Gemma4 per-layer model projection now quantizable (#309).**
- **Optimized shared MoE combine paths (#324)** and **shared fused gated-delta
  kernel between MLXLLM and MLXVLM (#32d51e5)**.
- **Qwen3.5 float32 dtype consistency in `gatedDeltaUpdate` (#317).**

## Tool Calling (iOS-relevant — local patch surface)

- **Sporadic bare-JSON tool-call handling + hardened JSON parser recovery (#205).**
  Upstream added `taggedStartMode`/bare-JSON paths and a `fallbackParser` in
  `ToolCallProcessor`. Our merge integrates these with our `pendingOutput`
  invisible-start-tag buffering and keeps the `XMLFunction` fallback in
  `JSONToolCallParser`'s decode-failure branch (under upstream's declared-tool gate).

---

## Merge Conflict Resolutions (from `3496df0`)

Six conflicts were resolved in files carrying our `// wangqi modified` patches:

1. `Chat.swift` — keep wangqi tool-call fields **and** upstream `audios`.
2. `ToolCallProcessor.swift` — `pendingOutput` buffering + upstream
   `taggedStartMode`/bareJSON + `fallbackParser`.
3. `Evaluate.swift` — flush both `pendingOutput` and `processEOS` buffers at EOS.
4. `JSONToolCallParser.swift` — XMLFunction fallback in decode-failure branch under
   upstream's declared-tool gate.
5. `Gemma4Text.swift` — adopt upstream's `kvState` enum.
6. `Qwen25VL.swift` — keep iOS chunked prefill (`state` nil) alongside upstream's
   MROPE state-seeding for non-iOS.

---

## Risk Assessment

**Overall: MEDIUM.** The new capabilities (audio input, LoRA, ChatSession,
ParoQuant) are additive and we do not yet call them, so they carry near-zero
regression risk. The real exposure is in files we patch locally that upstream also
rewrote in this range — all already conflict-resolved in `3496df0`, but each needs
on-device verification.

| Area | Risk | Why | Verify |
|------|------|-----|--------|
| Tool-call parsing (`ToolCallProcessor`, `JSONToolCallParser`, `Evaluate`) | **Medium-High** | Our `pendingOutput`/XML-fallback path was merged with upstream's new `taggedStartMode`/`fallbackParser`. Tool calling is core to the MLX workflow pipeline. | Run a tool-using MLX chat (e.g. web_search) end-to-end; confirm tool call is detected and emitted once. |
| Qwen2.5-VL prepare/MROPE (`Qwen25VL.swift`) | **Medium** | Upstream rewrote MROPE/rope_deltas and now seeds state via `LMOutput.State`; we keep iOS chunked prefill with `state` nil. Risk of degraded image-token positions on iOS chunks 2+. | Long-prompt VLM run on iOS device (`MLXVLMLongPromptTests`), check image grounding, no Metal crash. |
| Gemma4Text `kvState` enum | **Medium** | We adopted upstream's enum into our patched file; quantized KV-cache path also changed (#237). | Gemma-4 text + quantized KV generation on device. |
| Idefics3 / Qwen3VL prefill | **Low-Medium** | Files changed upstream; our always-chunked Idefics3 and Qwen3VL chunked-prefill patches must remain intact. | Confirm `chunkedVLMPrefill` still invoked per `helper/docs/mlx-swift.md` checklist. |
| `Chat.swift` audios field | **Low** | New param has a default; our tool-call fields preserved. Compile-only concern. | Build iOS + macOS targets. |
| Numerical (MoE combine, gated-delta fp32, shared kernel) | **Low** | Precision/perf changes, no API surface change for our callers. | Spot-check Qwen3.5 / MoE model output coherence. |

**Recommended verification before release:**
1. Build both `AIAssistant` (iOS) and `AIAssistantMac` schemes.
2. Run `MLXVLMLongPromptTests` on a real device for the patched VLM models.
3. Exercise one tool-calling MLX chat and one VLM image chat on device.
4. Confirm `MLX.Memory.clearCache()` unload path is unaffected.
