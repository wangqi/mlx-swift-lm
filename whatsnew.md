# mlx-swift-lm: tag-20260425 → tag-20260515

## Summary

23 commits merged from upstream `ml-explore/mlx-swift-lm` (plus the local merge commit preserving our `fallbackToolCallParser` and XML fallback support). This release is primarily a **stability and performance release** — no major model additions, but several high-impact fixes for iOS devices and significant speedups for hybrid SSM / GDN model families.

---

## New Features

### Speculative Decoding in ChatSession API (#181, #193)
`ChatSession` now exposes speculative decoding via a draft-model parameter. A small draft model proposes token candidates that the main model verifies in batch, reducing wall time on generation-heavy workloads. This was previously only accessible at the lower `generate()` API level.

### ParoQuant (Pairwise Rotation Quantization) Support (#164)
Added support for loading models quantized with ParoQuant — a quantization method that applies learned pairwise rotations before quantizing weights, improving accuracy at the same bit-width. Enables future `mlx-community` models with this quantization scheme.

### FusedGateUpSwitchGLU for MoE Models (#227)
`FusedGateUpSwitchGLU` combines `gate_proj` and `up_proj` into a single fused matrix multiplication for Mixture-of-Experts models that use a switched GLU activation. This reduces memory bandwidth pressure on Apple Silicon — beneficial on all devices, especially the Neural Engine path on iPhone/iPad.

### Tool-Aware Processing in VLM Processors (#167, #172, #174)
- `ToolCallProcessor` now receives the full tools schema for type-aware argument parsing, fixing silent type mismatches in structured output.
- Tools and `additionalContext` are now forwarded into `GlmOcr` and `SmolVLM2` processors, enabling tool use within vision pipelines.
- Stringified JSON tool call arguments (returned by some models as a JSON string instead of a parsed object) are now handled transparently.

---

## Performance

### 10× Faster Prefill on GDN Models — asyncEval Pipeline (#225)
Prefill chunks for Gated Delta Network (GDN) / hybrid SSM models are now pipelined via `asyncEval`, overlapping computation and data transfer on Apple Silicon. Benchmarked at **10× faster prefill** on GDN models (e.g., Qwen3 hybrid, Falcon H1) compared to the sequential evaluation path. This is the single largest user-visible improvement in this release for iPhone/iPad users running SSM-family models.

### GatedDelta fp32 State Precision (#224)
The GatedDelta recurrence state is now kept in `float32` (matching Python `mlx-lm`) instead of `bfloat16`. Previously, state accumulated bf16 rounding error across each recurrence step, leading to ~0.25 max absolute difference vs the reference at T > 1. Post-fix, the Swift path matches the Python ops path. No API change.

---

## Bug Fixes — iOS Critical

### IOSurface Exhaustion Fix in VLM Image Processing (#226, #268)
Two related fixes for `CIContext` misuse in the vision pipeline:
1. **Intermediate caching disabled** — `CIContext` was caching Metal-backed `IOSurface` objects internally between frames. On iOS, the `IOSurface` pool is small; this caused silent OOM or GPU command failures after a few vision turns. Caching is now disabled.
2. **Shared `CIContext` removed from media processing** — a single shared `CIContext` was held across concurrent vision requests, causing data races and IOSurface double-free. Each processing path now creates its own context.

These fixes make VLM image inference significantly more stable on iPhone / iPad, especially in multi-turn conversations with images.

### Hybrid SSM: 2× Memory Waste Eliminated (#229)
`segsum` dtype promotion in hybrid SSM models (e.g., Jamba, Falcon H1, Mamba-hybrid) was needlessly upcasting intermediate tensors, doubling peak memory usage during certain attention kernel paths. This is now fixed. On 8 GB iPhone models this can be the difference between a successful inference and an OOM termination.

### UserInput Multimodal Init Fixed (#182, #253)
`UserInput` initializers that accepted images or videos were not propagating them into the stored `self.images` / `self.videos` properties. This silently dropped multimodal context — text-only output from a VLM that received an image. Now fixed.

---

## Bug Fixes — Model Accuracy

### Gemma 4 MoE Router (#228)
Two bugs in the Gemma 4 MoE gating path:
1. `softmax` was applied before rather than after the expert logit computation, inverting routing probabilities.
2. Norm dispatches were not fused, causing redundant computations per expert. Both are now corrected.

### Gemma3n RoPE Offset (#280)
`ropeOffset` in `Gemma3NText` was incorrectly applied, causing positional encoding errors on longer sequences. Fixed to match the reference implementation.

### EmbeddingGemma Init-Order Crash + Dense Head (#223)
`EmbeddingGemma` had an init-order issue where the dense output head was configured before the model's hidden size was resolved, causing a crash on some variants. Also fixes the dense head hidden-size computation for non-standard vocab sizes.

### TokenRing 2D Prompt Flatten (#168, #170)
`TokenRing.loadPrompt` could receive 2D `[batch, seq]` prompt arrays from certain code paths but assumed 1D. The token ring now flattens 2D inputs, preventing index-out-of-bounds on hybrid/SSM models with batched prompts.

---

## Concurrency

### TokenLoopHandler Sendable Removed (#284)
`TokenLoopHandler` no longer requires `Sendable` conformance. This was blocking adoption in non-`Sendable` contexts and the conformance was unnecessary given the existing actor isolation. No behavior change; reduces `@unchecked Sendable` boilerplate at call sites.

---

## Risk Assessment

| Area | Risk | Notes |
|------|------|-------|
| asyncEval prefill pipeline | **Low–Medium** | New scheduling path for GDN models; existing non-GDN models unaffected. Tested on M5 Max. iOS simulator behavior may differ slightly from device. |
| fp32 GatedDelta state | **Low** | Output quality improves; no API change. Slightly higher peak memory for GDN state tensors (fp32 vs bf16), negligible on device. |
| CIContext / IOSurface fix | **Low** | Strictly defensive; eliminates a crash path. No functional change to vision output. |
| segsum dtype fix | **Low** | Reduces peak memory — no output change. |
| UserInput multimodal init | **Low** | Bug fix; callers relying on the broken silent-drop behavior would have to explicitly re-add images, but this scenario is unlikely. |
| ParoQuant | **Low** | New code path; only activates for ParoQuant-quantized models not yet in our registry. |
| Tool schema forwarding | **Low** | Additive; improves parsing correctness for existing tool-calling flows. |
| FusedGateUpSwitchGLU | **Low** | Fused kernel path guarded by model config; falls back automatically if unsupported. |
| Gemma 4 MoE router | **Low** | Bug fix for existing Gemma 4 MoE users; no regressions for non-MoE models. |

**Overall upgrade risk: Low.** The release is dominated by targeted bug fixes and one major performance improvement (asyncEval prefill). The most impactful change for iOS users is the IOSurface exhaustion fix (#226 / #268) — VLM image inference becomes meaningfully more stable on device.
