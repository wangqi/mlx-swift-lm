# mlx-swift-lm Upgrade — `tag-20260621` → `tag-20260703`

**Merged:** 2026-07-03
**Upstream base:** `ml-explore/mlx-swift-lm` main (PRs #230, #330, #342, #345, #360, #363, #365, #366, #368, #371, #372, #373, #377, #378, #380, #385)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

16 upstream PRs (17 commits incl. merge). For our iOS integration the headline is upstream PR #345, which
implements 3-D multimodal RoPE (M-RoPE) inside the **Qwen2-VL** language model — the same file that carries our
fork-local iOS `chunkedVLMPrefill` patch. The overlap was resolved during the merge with a hybrid split: the
text-only path stays chunked on iOS/Catalyst (M-RoPE positions are `nil` there), while the image/video path —
which now carries M-RoPE spatial positions that cannot be sliced per chunk — falls through to single-shot prefill
on every platform. No mlx-swift / mlx-core version move, so the PrismML low-bit patch is untouched.

---

## Highlights

### On-device / iOS memory & stability
- **Qwen2-VL M-RoPE (#345)** now runs through the language model, so image tokens get true 3-D spatial positions
  and bounding-box / layout tasks stop drifting with generation length. On iOS the image path is single-shot
  (short image prompts); the long text-only path keeps our chunked prefill. Our `chunkedVLMPrefill` patch count is
  unchanged across all 7 touched VLM files.
- **Extensible KV-cache compression (#230)** — `GenerateParameters.kvScheme` (string) selects a KV compression
  strategy (`"affine4"`/`"affine8"` built in) and **overrides `kvBits` when set**. `nil` preserves our current
  iOS behavior (`kvBits = 4`, `quantizedKVStart = 64`); no code change needed to keep today's memory profile.
- **Runtime stop-string handling (#372)** — generation can halt on arbitrary stop strings, correctly spanning
  token-chunk boundaries. Opt-in; empty stop set preserves current behavior.

### New models
- **Mixtral (#378)** — sparse MoE LLM (Mistral-style GQA attention + top-k SwitchGLU experts), registered as
  `"mixtral"`. Loads both full-precision and pre-quantized checkpoints.
- **Mamba2 (#380)** — first pure state-space-model LLM (no attention KV cache; per-layer `MambaCache`),
  registered as `"mamba2"`.
- **LFM2.5 bidirectional embedders (#365)** — LFM2.5-Embedding-350M (CLS-pooled dense) and LFM2.5-ColBERT-350M
  (late-interaction) added to `MLXEmbedders`, `model_type "lfm2"`.

### New capabilities / API
- **Reproducible sampling seed (#377)** — `GenerateParameters.seed: UInt64?` threads a per-request seed into each
  sampler's `RandomState`; `nil` keeps the existing entropy seed. Per-request, so concurrency-safe (no shared RNG).
- **Correlated tool-call transcripts (#360)** — optional `ToolCall.id` plus OpenAI-style `tool_calls` /
  `tool_call_id` metadata, wired through all six VLM generators. Lets assistant tool calls and tool results be
  paired across turns; relevant to `AIChatModelMLX` tool handling and `MCPToolIntegration2`.

### Correctness fixes
- **Gemma 4 loading (#330, #342, #363, #366)** — KV-shared layers own no `k_proj`/`v_proj`/`k_norm`; QAT and some
  PTQ checkpoints prune (or, for the 12B unified model, add `vision_embedder`) those tensors. Sanitize now drops
  the redundant/extra weights on both the LLM and VLM text backbones, fixing `keyNotFound` / "unhandled keys"
  load failures (e.g. `gemma-4-E2B-it-qat-4bit`, `gemma4_unified` 12B).
- **Gemma 4 VLM end-token defaults (#373).**
- **Falcon-H1R correctness, cache, and preset fixes (#368).**
- **RoPE config validation (#371)** — invalid RoPE configurations are rejected up front instead of producing
  silently wrong positions.

### Build / toolchain
- `.swift-format` sets `indentConditionalCompilationBlocks = false` (#385) — cosmetic; aligns `#if/#else/#endif`
  bodies with the directive. No source semantics.

### Tests
- Upstream added `MixtralTests`, `Mamba2Tests` (no model download), LFM2.5 embedder parity tests, RoPE-validation
  positive-path tests, and seed determinism/divergence tests. Our fork-local
  `testcases/ai/mlx/MLXVLMLongPromptTests.swift` and `thirdparty/mlx-swift/Tests/MLXTests/QuantizationTests.swift`
  are unaffected by the merge.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| VLM prefill (Qwen2-VL) | M-RoPE now in the LM; image path single-shot, text-only path stays chunked (#345) |
| KV cache | New `kvScheme` string param; overrides `kvBits` only when set — `nil` keeps today's iOS profile (#230) |
| Generation loop | Runtime stop-string support across chunk boundaries; opt-in (#372) |
| Sampling | Optional per-request `seed` for reproducibility; `nil` = current entropy behavior (#377) |
| Tool calling | Correlated tool-call IDs / OpenAI-style metadata through all VLM generators (#360) |
| Model loading | Gemma 4 QAT/PTQ/12B-unified load fixes (#330, #342, #363, #366) |
| Low-bit quant | No mlx-swift/mlx-core version move — PrismML 1-bit/2-bit patch unaffected |

---

## Risk Assessment — **3 identified risks** (1 medium, 2 low)

### R1 — Qwen2-VL M-RoPE overlaps the iOS chunked-prefill patch (MEDIUM)
Upstream PR #345 added 3-D M-RoPE inside `Qwen2VL.swift`, the same `prepare(_:cache:windowSize:)` that carries
our `chunkedVLMPrefill` patch. The merge resolved this with a hybrid split (comment
`wangqi modified 2026-07-03 (hybrid chunk merge)`): the **text-only** path (`allPixels == nil`, `positionIds ==
nil`) stays chunked on iOS/Catalyst using cache-offset sequential RoPE; the **image/video** path carries M-RoPE
`positionIds` `[3, batch, seq]` and goes single-shot because chunking without slicing `positionIds` in lockstep
would feed wrong spatial positions. The old/new `chunkedVLMPrefill` counts match across all 7 touched VLM files
(FastVLM, Gemma4, GlmOcr, Mistral3, Qwen25VL, Qwen2VL, Qwen3VL), so no patch was dropped.
*Verify:* run `testcases/ai/mlx/MLXVLMLongPromptTests.swift` (Qwen2-VL) on device; confirm a long text-only VLM
prompt still generates without the `[1, h, N, N]` Metal abort, and that an image prompt with layout/bounding-box
output is spatially correct. Regression coverage: `MLXVLMLongPromptTests.swift`.

### R2 — `kvScheme` overrides `kvBits` when set (LOW)
`GenerateParameters.kvScheme` (#230) supersedes `kvBits` whenever it is non-nil. Our iOS KV path sets `kvBits = 4`
and never sets `kvScheme`, so the default `nil` preserves current behavior. Risk is only if a future config path
starts populating `kvScheme` and silently disables the 4-bit KV cap that keeps iOS under the jetsam limit.
*Verify:* confirm no code sets `GenerateParameters.kvScheme`; keep the iOS `kvBits = 4` / `quantizedKVStart = 64`
path as the source of truth.

### R3 — New Mamba2 / Mixtral models are not memory-verified on iOS (LOW)
Mamba2 (pure SSM) and Mixtral (sparse MoE) are new LLM architectures. Neither overrides
`prepare(_:cache:windowSize:)` nor is a VLM, so the chunked-prefill crash surface does not apply. Mamba2 uses its
own `MambaCache` (no attention KV), which the iOS `kvBits` path does not touch. They are not surfaced in
`models_*.json` yet, so there is no user-facing exposure until deliberately added.
*Verify:* if either is later added to `helper/models_*.json`, run a device memory check before shipping.

---

## Follow-ups
1. Build both schemes: `AIAssistant` iOS **BUILD SUCCEEDED (2026-07-03)**; `AIAssistantMac` still to run.
2. Run `testcases/ai/mlx/MLXVLMLongPromptTests.swift` on device for R1 (Qwen2-VL text-only long prompt + image
   bounding-box correctness).
3. No new VLM model files added, so the patched-models list in `helper/docs/mlx-swift.md` is unchanged. Mamba2 /
   Mixtral / LFM2.5 embedders remain un-surfaced until added to `models_*.json`; decide separately whether to
   expose them.
4. Version axes unchanged (`mlx-swift 0.31.4` / `mlx-core 0.31.1`) — no PrismML re-apply; QuantizationTests gate
   not re-run (patch base untouched).
