# mlx-swift-lm: tag-20260425 → tag-20260522

## Summary

12 commits merged from upstream `ml-explore/mlx-swift-lm` (including our local merge commit preserving `Gemma4FunctionParser` double-brace JSON fallback and a `Qwen3VL.swift` patch reconciling the new `state:` parameter from PR #283 with our existing chunked-prefill callback). This is primarily a **stability and Gemma 4 performance release** — no new model families, but a meaningful decode speedup, several crash fixes that hit iOS prefill paths, and a structural change to how M-RoPE positions are threaded through VLM forward passes.

---

## New Features / Performance

### Gemma 4 text decode: +23.8% throughput (PR #249)
`Gemma4DecoderLayer` now fuses three op pairs (post-attention residual, post-MLP residual, PLE gating) into `compile()` helpers, reducing per-op MLX dispatch overhead. Measured **51.2 → 63.4 tok/s median on M4 Max**. Prefill and numerical output are unchanged. `rms_norm_eps` is hardcoded to `1e-6` with a `precondition` guard against future checkpoints diverging.

### LLM generation benchmark helper (PR #248)
`BenchmarkHelpers.benchmarkLLMGeneration` + `LLMGenerationStats` measure prefill (prompt processing) and decode (generation) throughput in one helper, mirroring the existing loading/tokenization helpers (warm-up + multi-run timing). `temperature=0` so runs are deterministic. Useful for evaluating fusion patches, custom kernels, or KV-cache tweaks without spinning up a separate CLI.

---

## Bug Fixes (iOS-impacting)

### Gemma 4 attention crash when `vProj` is nil (PR #247)
With `attentionKeqV=true`, `v_proj` does not exist and `v` shares `k`'s values. The previous code transposed `v = k` a second time after `k` had already been transposed to `(B, nKvHeads, L, head_dim)`, producing an incompatible shape and crashing in `broadcast_shapes`. Reproduces with `mlx-community/gemma-4-31b-it-4bit`. **Fix:** in the nil-`vProj` branch, apply `vNorm` directly to the already-transposed `k` and skip the extra transpose. The `vProj` branch is unchanged.

### Gemma 4 VLM 1D-token-input prefill crash (PR #241)
When callers construct `LMInput` directly (e.g. for manual KV-cache reuse), tokens arrive as 1D `(L,)` instead of 2D `(1, L)`. `processedPerLayerInputs` then became 3D and the 4D subscript on `finalPerLayerInputs` crashed in `mlx_array_dim`. The first request still succeeded because the autoregressive step adds `.newAxis`, but continuation requests crashed on initial prefill — a path our app hits on long sessions. **Fix:** expand 1D inputs / 2D `inputsEmbeds` to add a leading batch dim at the top of `callAsFunction` (zero-copy reshape).

### Gemma 4 vision pooler kernel derivation (PR #290)
The pooler kernel was previously derived from the real patch count, which could yield `kernel=2` at the 280-token budget instead of the expected 3, causing real patches to map to **zero rows** in the einsum output (silently degraded VLM accuracy). **Fix:** new `gemma4VisionPoolingKernel(paddedPatchCount:outputLength:)` derives the kernel from `pooledHiddenStates.dim(1)`; regression tests added for all five budgets `{70, 140, 280, 560, 1120}`.

### Idefics3 prefill chunking (PR #297)
`Idefics3.prepare()` now honors `windowSize` so prompt prefill is never chunked when it should be a single pass. The prior path could chunk and break long prompts on macOS; the fix also resolves a parallel issue in our Qwen3VL chunked-prefill (see merge notes).

---

## API / Structural Changes

### `LMOutput.State`-based M-RoPE position passing (PR #283)
**This is the load-bearing change for VLM models in this round.** Models no longer mutate state during eval. Instead, each forward returns the position-id state via `LMOutput.State`, and callers thread it back in on the next step. Affected here: `Qwen35`, `GlmOcr`, `Qwen3VL` (the latter required our local patch — see below). The autoregressive path uses `rope_deltas` to compute sequential positions; the prefill path computes positions from `getRopeIndex`. GPT-OSS was also synced with mlx-lm to ensure no sinks are missing.

**Local patch applied (commit `1304cbc7`):** Our `Qwen3VL.swift` chunked-prefill loop now passes `state: nil` per chunk so each chunk's `callAsFunction` lazily computes (and caches into its own local `State` copy) M-RoPE positions. Chunks 2+ remain on the ropeDeltas-based autoregressive path. This reconciles PR #283's signature change with our existing chunked-prefill callback used to keep Qwen3VL prefill within iOS prefill budgets.

### `GemmaFunctionParser` parameterized (PR #183) — merged with local override preserved
Upstream's parameterized parser was adopted; our `Gemma4FunctionParser` double-brace JSON fallback is preserved on top.

---

## Build / CI

- Removed the SDK build-version probe from CI workflow — it was informative but caused install-time problems (PR #306).
- CI docs check folded into the macOS build job to reuse a single runner (PR #286).

Neither change affects the shipped library or our app build.

---

## Risk Assessment for This Upgrade

**Overall risk: Low–Medium.** The new code is mostly fixes the app benefits from directly; one structural change (PR #283) touched a code path we already patched.

| Area | Risk | Notes |
|------|------|-------|
| Gemma 4 text generation | **Low** | Fused-`compile()` decode is a pure perf win; numerical output unchanged per upstream test; `rms_norm_eps` precondition will trip loudly if a divergent checkpoint ever ships. |
| Gemma 4 31B VLM | **Low** | Fixes a crash we could have hit on 4-bit checkpoints; no behavior change for fp16 path. |
| Qwen3VL chunked prefill | **Medium** | Local patch reconciles `state:` API with our chunked-prefill loop. State is recomputed per chunk (not shared), so chunks 2+ rely on ropeDeltas — correct under upstream semantics but worth eyeballing first-run on a fresh long-context VLM prompt on iOS. |
| Qwen35 / GlmOcr | **Low–Medium** | PR #283 reshapes how positions move through `LMOutput`. Our app does not consume `LMOutput.State` externally, so the change is internally contained; first-load smoke test recommended on both models. |
| Idefics3 | **Low** | We don't ship Idefics3 by default; if a user adds one, prefill is now correct. |
| `BenchmarkHelpers` | **None** | Additive only; existing helpers unchanged. |
| iOS memory / prefill | **Low** | No regressions identified. Gemma 4 VLM 1D-input fix removes one known crash path on continuation turns. |

**Recommended smoke tests before shipping:**
1. Gemma 4 4-bit text — confirm decode tok/s improvement and identical output to last build.
2. Qwen3VL on iPad/iPhone — long image + text prompt that exceeds one prefill chunk; verify no position drift in the streamed reply.
3. Qwen3.5 text — multi-turn continuation to confirm `LMOutput.State` plumbing.
4. GlmOcr — single OCR turn on a sample image.
