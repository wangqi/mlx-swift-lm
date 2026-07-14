# mlx-swift-lm Upgrade — tag-20260703 → tag-20260714

**Range:** `tag-20260703..tag-20260714`
**Date:** 2026-07-14
**Upstream:** ml-explore/mlx-swift-lm (merged into fork `main`)

This upgrade is dominated by **model-correctness fixes** for the VLM (vision) and
Gemma families plus one significant **Apple Silicon prefill speedup**. There are
no breaking API changes to how the app loads or runs models; the only signature
change (`prefillStepSize` becoming optional) is source-compatible with our call site.

---

## Highlights for iOS / Apple Silicon

### Performance

- **Gemma 3 prompt prefill up to 2.6x faster (#346).** `Gemma3TextModel.prepare`
  now prefills all-but-the-last prompt token through the inner model (KV-cache only,
  **skipping the 262k-vocabulary `lm_head`**) and hands only the final token to the
  token iterator. Measured on `translategemma-4b-it-4bit` (577-token prompt, greedy):
  prefill 177 → 463 tok/s, 3253 → 1246 ms, **byte-identical output**. The chunk size
  honors an explicit `GenerateParameters.prefillStepSize` and otherwise defaults to
  128 (tuned for asyncEval CPU/GPU pipelining on Apple Silicon).

### Vision-Language (VLM) correctness

- **Qwen3-VL dark/low-contrast images now readable (#411).** The image preprocess
  path was feeding the ViT linear-light values instead of gamma-encoded sRGB. Near-black
  text on a dark background reached the model with ~12x less contrast than the HF
  reference and was unreadable. The sRGB tone curve is now applied (matching the
  sibling video path and Qwen2.5-VL/Qwen2-VL).
- **Qwen3.5-VL garbage output fixed (#403).** `Qwen35.sanitize` (VLM) applied the
  RMSNorm `+1` offset unconditionally; on pre-converted MLX checkpoints this
  double-shifted every layernorm and produced garbage tokens. The VLM path now
  gates the shift exactly like the LLM path.
- **Qwen2.5-VL position drift fixed (#419).** The prefill `LMOutput.State`
  (MROPE positionIds / ropeDeltas) was dropped on the `TokenIterator` `.logits`
  path, so the first decode step ran without them — position drift after an image
  block and degenerate empty output on dense frames. The standard path now carries
  the state like the `.tokens` and speculative paths.
- **Gemma 4 VLM load fixed (#390).** KV-shared tail layers were built with
  `kvSharedOnly: false`, declaring `k_proj`/`v_proj` they don't own and causing
  strict-loader `keyNotFound` failures on real checkpoints (e.g. `gemma-4-e4b-it-4bit`).
  Init now uses the same KV-shared predicate as the rest of the stack.

### Tool calling

- **Gemma tool arguments coerced by schema type (#388).** `GemmaFunctionParser`
  was missing the `convertParameterValue` calls, so every tool-call argument was
  passed as a string instead of its declared type. Arguments are now converted to
  the types the tools expect.

### Model loading

- **Honor safetensors index when loading weights (#408).** `loadWeights` now reads
  `model.safetensors.index.json` (via the new `safetensorWeightURLs` helper) and
  loads only the referenced shards when an index is present, falling back to
  enumerating all `.safetensors`. *(Merge conflict in this file resolved on our side:
  upstream's index-honoring loop was adopted and the fork's nil-enumerator crash-guard
  — `ModelLoadError.directoryNotAccessible` — was preserved by moving it into the new
  helper's fallback, replacing upstream's reintroduced force-unwrap.)*

---

## Changes with no effect on this app

These are real upstream fixes but touch code paths the app does not use:

- **ChatSession consumer-cancellation deadlock fix (#413).** We do not use
  `MLXLMCommon.ChatSession`; the app runs its own generation loop and cancellation
  via `generationChatSessionId`.
- **Qwen3 embedder attentionMask fix (#418).** We embed via CoreML
  (`CoreMLTextEmbedder` / `EmbeddingModelManager`), not `MLXEmbedders`.
- **CI / lint only:** pin swift-format 603.0.0 (#386, #416), and fix
  `mac_build_and_test` for mlx-swift ≥ 0.31.5 via `-skipPackagePluginValidation`
  plus swift-format 603 conformance (#404). Dev-tooling only, no shipped code.

---

## Risk Evaluation

**Overall risk: LOW.** This cycle is almost entirely narrow, well-tested correctness
fixes (each ships a regression test) rather than architectural change. Two items touch
paths we actually exercise; both are accounted for.

| # | Change | Touches our path? | Risk | Notes |
|---|--------|-------------------|------|-------|
| #408 | Honor safetensors index (Load.swift) | **Yes** — every model load | **Medium** | Our fork's nil-guard preserved through the merge. New behavior only differs when a valid `model.safetensors.index.json` is present (loads referenced shards); otherwise identical enumeration. |
| #346 | Gemma 3 chunked prefill / `prefillStepSize: Int?` | **Yes** — `AIChatModelMLX.swift:1077` | **Low** | Signature changed `Int` → `Int?`; our assignment `params.prefillStepSize = chatConfig.n_batch` (only when `> 0`) still compiles and works. We override Gemma 3's tuned default of 128 with `n_batch` (512), but the `lm_head`-skip speedup applies regardless of chunk size. |
| #388 | Gemma tool-arg type coercion | Indirect (internal parser) | **Low** | Pure improvement; only affects Gemma tool calls, which previously passed string args. |
| #411, #403, #419, #390 | Qwen3-VL / Qwen3.5-VL / Qwen2.5-VL / Gemma 4 VLM fixes | Yes if those models are run | **Low** | Each is a targeted fix with a regression test; strictly improves correctness for the affected model. |
| #413, #418, #386, #416, #404 | ChatSession / MLXEmbedders / CI | **No** | **None** | Unused code paths or dev tooling. |

**Watch-items after upgrade:**
1. Smoke-test one **Gemma 3** text model (prefill speedup path) and confirm output is unchanged.
2. Smoke-test one **VLM** model with an image (Qwen3-VL / Gemma 4) to confirm the load and image-preprocess fixes behave.
3. Confirm MLX model loading still succeeds for a model **with** and **without** a `model.safetensors.index.json` (the #408 branch).

**Not addressed by this task (tracked separately in the upgrade skill):** mlx-swift /
mlx-core version-pin reconciliation and re-application of the PrismML 1-bit/2-bit
quantization patch. Note #404 references upstream requiring **mlx-swift ≥ 0.31.5**
(CudaBuild plugin) for its CI — verify our pin during the pin-reconciliation step.
