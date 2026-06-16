# mlx-swift-lm Upgrade — tag-20260607 → tag-20260616

**Upgrade date:** 2026-06-16
**Previous pin:** `tag-20260607`
**New pin:** `tag-20260616`
**Commits merged:** 8 (1 merge commit + 7 substantive changes)
**Diff size:** 47 files, +6961 / -283
**App integration file:** `ai/AIChatModelMLX.swift` (no source-API changes required)
**Related design doc:** `helper/docs/mlx-swift.md`

---

## Summary

This is a **model-correctness and Gemma 4 performance** upgrade. There are no
breaking public-API changes to `loadContainer(from:using:)`, `UserInput`,
`MLXLMCommon.generate(...)`, or the tokenizer bridge, so `AIChatModelMLX.swift`
compiles unchanged. The bulk of the diff is new test/fixture infrastructure for
Gemma 4 Multi-Token-Prediction (MTP) speculative decoding, plus targeted
inference fixes for Gemma 4, Falcon H1, LFM2-MoE, and Qwen2/2.5-VL.

---

## What changed

### 1. Gemma 4 Multi-Token-Prediction (MTP) speculative decoding (#308) — Feature

A full MTP speculative-decoding stack lands in `MLXLMCommon` and `MLXVLM`:

- `MTPDrafterModel` protocol + `MTPDrafterContext` / `MTPDrafterContainer`
  (mirroring `ModelContext` / `ModelContainer`).
- `Gemma4AssistantDraftModel` — a 4-layer Q-only drafter that cross-attends to
  the target model's pooled K/V, loaded via `MTPDrafterModelFactory`
  (`gemma4_assistant` registry entry).
- `MTPSpeculativeTokenIterator` driving the accept/reject round loop, with new
  `generate(...)` / `generateTokens(...)` overloads.
- `GenerateCompletionInfo` gains MTP counters (`proposedDraftTokens`,
  `acceptedDraftTokens`, `passthroughReason`).
- Empirical (31b-it-8bit + 31B-assistant-bf16, temp=0): ~60% acceptance,
  ~13.6 tok/s at bs=4/mt=64.

**Opt-in:** MTP requires loading a *separate drafter model* and calling the new
generate overloads. Our `AIChatModelMLX` uses the standard
`MLXLMCommon.generate(input:parameters:context:)` path and does **not** wire a
drafter, so this feature is dormant until we deliberately adopt it. Zero runtime
impact on the current app.

### 2. Gemma 4 vision prefill now honors `windowSize` on all platforms (#337) — Improvement / iOS-relevant

`Gemma4.prepare(_:cache:windowSize:)` was rewritten upstream to chunk **both**
the merged image+text embedding path **and** the text-only path in
`windowSize`-sized slices, with `asyncEval` between chunks. This is upstream's
own equivalent of our `chunkedVLMPrefill` helper, and it now also slices the
paired **per-layer inputs** that previously blocked us from chunking Gemma 4's
vision path.

**Impact on our patches:** Our prior `// wangqi modified` `chunkedVLMPrefill`
patch on Gemma 4's text-only path is gone (overwritten by the merge) and
**superseded** by upstream's native chunking, which is strictly broader (covers
the vision path too). This resolves the "Gemma4 vision path is single-shot"
known exception recorded in `helper/docs/mlx-swift.md`. The new code has no
`#if os(iOS)` guard, so macOS also chunks Gemma 4 now (minor throughput change,
acceptable). Qwen2VL/Qwen25VL/Qwen35/etc. retain their own `chunkedVLMPrefill`
patches unchanged.

### 3. Gemma 4 cross-layer KV sharing fix in the no-cache forward pass (#333) — Bug fix

Dropped a `hasExplicitCache &&` guard so shared-KV layers gate only on the
layer index. Without it, no-cache forwards (embedding extraction, retrieval,
batched eval) silently re-projected K/V on shared layers, violating Gemma 4's
invariant. Cached generation was already correct.

### 4. Falcon H1 aligned with upstream MLX inference (#331) — Bug fix / iOS-relevant

Fixes tied-embedding output projection and scaling, routes attention through
the common cache-aware causal path, advances Mamba cache metadata during
generation, reports per-layer KV head counts correctly, and **chunks SSM
prefill to reduce long-prompt memory and latency** — directly helpful on
memory-constrained iOS devices. Also mirrors upstream `ArraysCache` length
handling for hybrid/batched paths (left-padding and per-row lengths preserved).

### 5. LFM2-MoE sigmoid routing + expert-bias fix (#332) — Bug fix

LFM2-MoE is sigmoid-gated; the block had incorrectly applied softmax and folded
`expert_bias` into the combination weights. Now the bias steers top-k selection
only, and weights come from the unbiased sigmoid scaled by
`routed_scaling_factor` (mirrors `ml-explore/mlx-lm#1354`). Affects LFM2-MoE
output quality only.

### 6. Qwen2/2.5-VL default image pixel budget (#243) — Improvement / iOS-relevant

Qwen2.5-VL shipped `max_pixels = 12,845,056` (~12x the model card's recommended
`1280*28*28` budget). Upstream now defaults to the recommended budget. Callers
can still override via `UserInput.Processing.minPixels / maxPixels`. **Lower
default memory and faster image prefill on iOS** for these models, with a small
possible quality reduction on very high-resolution images (override available).

### 7. Test/cleanup (#326, #341) — non-shipping

Speculative-decode tests fixed to run in float16 (avoids float32/tf32 mismatch);
reference cleanup per author request. No runtime code path affected.

---

## Risk evaluation

**Overall risk: LOW–MEDIUM.** No public-API breakage; our integration compiles
unchanged. The merge did touch two of our patched files, so a build + VLM
long-prompt regression run is warranted.

| Area | Risk | Notes |
|------|------|-------|
| Public API / `AIChatModelMLX.swift` compile | **Low** | `loadContainer(from:using:)`, `UserInput`, `generate`, tokenizer bridge all unchanged. |
| Gemma 4 vision (`#337`) | **Medium** | Our `chunkedVLMPrefill` patch was overwritten by upstream's native windowSize chunking. Functionally superseded, but must verify Gemma 4 vision long-prompt no longer crashes on iOS and outputs are correct. Add/keep Gemma 4 in `MLXVLMLongPromptTests`. |
| Gemma 4 no-cache fix (`#333`) | **Low** | Improves correctness of embedding/retrieval/batched paths. |
| Falcon H1 (`#331`) | **Low–Medium** | Substantial inference rewrite (Mamba cache, SSM chunking, tied embeddings). Improves long-prompt memory on iOS but is a behavior change; smoke-test if any Falcon H1 MLX model is shipped. |
| LFM2-MoE (`#332`) | **Low** | Output-quality correctness fix; only affects LFM2-MoE models. |
| Qwen2/2.5-VL budget (`#243`) | **Low** | Lower memory; possible minor quality drop on very large images, overridable. Our chunkedVLMPrefill patches on these files are intact. |
| MTP speculative decoding (`#308`) | **None (dormant)** | Opt-in only; not wired in our generate path. |
| iOS memory limits / `MLX.Memory.clearCache()` unload | **None** | Untouched by this upgrade. |

### Required verification before shipping
1. Build `AIAssistant` (iOS) and `AIAssistantMac` schemes.
2. Run `testcases/ai/mlx/MLXVLMLongPromptTests.swift` — confirm Gemma 4 vision
   and Qwen2/2.5-VL long prompts pass (no Metal abort) on iOS.
3. Smoke-test one Gemma 4 vision chat (image + long text) on a real device.
4. Update `helper/docs/mlx-swift.md`: Gemma 4 is no longer a chunked-prefill
   exception — its vision path is now chunked natively upstream.

### Patch-tracking follow-up
Our `chunkedVLMPrefill` patch on Gemma 4's text path was dropped by the merge.
Decision: **do not re-apply** — upstream's native windowSize chunking is the
better, broader replacement. Re-confirm Qwen2VL/Qwen25VL `// wangqi modified`
markers survived (verified present: 1 chunkedVLMPrefill call each).
