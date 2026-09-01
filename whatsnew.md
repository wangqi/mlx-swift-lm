# mlx-swift-lm Upgrade — `tag-20260810` → `tag-20260831`

**Merged:** 2026-08-31
**Upstream base:** `ml-explore/mlx-swift-lm` main @ `ad00de5` (54 upstream commits; PRs #511, #592, #598, #587, #594, #572, #573, #568, #569, #585, #583, #582, #329, #575, #574, #576, #571, #567, #565, #564, #570, #544, #562, #375, #541, #557, #555, #507, #549, #559, #556, #531, #546, #509, #527, #538, #512, #534, #348, #532, #533, #530, #484, #529, #351, #521, #514, #523, #526, #516, #490, #519, #520, #475)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

This upgrade brings 54 upstream commits. The single most important item for our integration is **PR #475 (prompt cache: persist model state, wire Qwen3-VL and GLM-OCR restoration, and fail closed)**. It gives Qwen3-VL, Qwen3.5-VL and GLM-OCR their own windowed `prepareContinuation` — vision tower, image→token merge, M-RoPE positions and per-layer deepstack tensors all sliced in lockstep, routed whenever `cacheOffset > 0 || tokens > window` on **every** platform. That retires the **last two** `chunkedVLMPrefill` fork patches (Qwen3VL, GlmOcr), so every `MLXVLM/Models/*.swift` file is now byte-identical to upstream for the first time since the fork began patching them.

The same PR also **fails closed**: `QwenVL.continuationAnchor` throws `ContinuationStateError.missingState` when a warm cache arrives without the model's M-RoPE anchor in `LMOutput.State`. `ChatSession` threads that state across turns; our path drives `generate` directly and holds only `[KVCache]` — so this needed an app-side fix, without which **every warm-cache VLM turn would have failed**. See R1.

The second theme is **throughput**: `up to ~1.8x faster model loads` (#575), fused Qwen GDN input projections (#572), direct MoE expert reduction (#573), shared fused router top-k across five more model families (#568/#567), compiled decode segments generalized to Qwen 3 Next (#569), and single-dispatch TurboFlash for short contexts (#520/#570). None of it needs a configuration change on our side.

---

## Highlights

### Prompt cache & continuation (the area our fork invests in most)
- **Windowed continuation for Qwen3-VL / Qwen3.5-VL / GLM-OCR, and it fails closed (#475).** `prepare` routes into `prepareContinuation` whenever the cache is warm or the prompt exceeds the window; the vision tower runs once over the remainder and the language model is driven in `prefill`-sized chunks, bounding attention scratch to `[heads, chunk, L]`. M-RoPE positions come from a position anchor (`QwenVL.continuationAnchor` = cache offset + the rope delta in `state`) rather than absolute zero. A warm cache with no anchor **throws** rather than silently repositioning the remainder.
- **Cache reuse enabled for text-only inputs (#549).** Qwen3-VL's processor no longer attaches an all-ones `int8` mask to text-only prompts (`LMInput(tokens:)` instead of `LMInput(text: .init(tokens:mask:))`). This is upstream arriving at the same conclusion our 2026-08-23 fork patch did — from the other end, by removing the inert mask rather than relaxing the veto that tripped on it. **The fork patch is still load-bearing**: upstream fixed only Qwen3-VL, while FastVLM, Pixtral, Idefics3, SmolVLM2, Mistral3, MuseGlimmer, GlmOcr, Gemma4 and PaliGemma all still attach an all-ones mask on their text-only branch. Upstream's `testExactPrefixReuseRebuildsWhenPreparedInputHasMask` asserts the opposite of the fork and is adapted in the fork's copy — expect that collision on every future merge (recorded in `UPGRADING.md`).
- **Reuse is reported, not discarded (#559).** `GenerateCompletionInfo` gains `cachedPromptTokenCount`, with derived `totalPromptTokenCount` and `cacheEfficiency`; `promptTokenCount` is documented as *prefilled* tokens only. **Attribution happens at the `ChatSession` boundary**, so on the `generate(input:cache:…)` path we drive it reports 0 — see R4.
- **`maxKVSize` is honored across full, sliding-window and hybrid caches (#514).** `newCache` in ~20 model files (AfMoE, BaichuanM1, Exaone4, FalconH1, GPTOSS, Gemma3/3n/4/4Text, GraniteMoeHybrid, Jamba, LFM2, LFM2MoE, MiMoV2Flash, Mistral3Text, Nanbeige, NemotronH, Olmo3, Qwen35, Qwen3Next) moved onto `makeAttentionKVCache` / `makeSlidingWindowKVCache`. **This removes the reason our `resolveKVAndSampler` gives for never setting a capacity** — see R5.
- **Variance-normalized KV cache (#329).** KVarN-inspired: Hadamard rotation, dual-axis log-domain variance normalization, asymmetric K/V quantization of completed tiles, exposed as `VarianceNormalizedKVCacheConfiguration` plus legacy `varn*` schemes. Explicitly *slower than the default cache on decode by design* — a memory-bound long-context trade, not a speed one.
- **Speculation past the sliding window (#516).** `RotatingKVCache` gains staged transactional speculative rounds (`beginRound`/commit/`rewindLastRound`, `logicalView(tail:)`), so a rotating cache no longer needs post-hoc trimming that breaks once the ring has wrapped.

### Performance
- **Weight loading parallelized — up to ~1.8x (#575).** Each safetensors file's tensors are read from its own header, ordered by file offset, split into contiguous byte-balanced groups (~total / clamp(cores, 4…16), min 256 MiB), and evaluated from `concurrentPerform` work items, overlapping read/copy/allocation that a single `eval` serializes. The old `F_RDADVISE` prefetch measured <1% and often negative and was removed. Measured on an M4 Pro / NVMe ~6.1 GB/s: Muse-Glimmer-30B-4bit (18 GB, cold) 5.6–6.1s → 3.1s weight load; Qwen3.5-9B-8bit (9.7 GB, cold) 2.2–2.6s → 1.6–1.8s, ~2x warm. Checksum-verified bit-identical against the serial loader; a file whose header does not parse falls back to one whole-file work item.
- **Fused Qwen GDN input projections (#572)**, and inference preparation moved onto the `LanguageModel` lifecycle (`prepare()`).
- **Direct Qwen MoE expert reduction, on by default (#573).**
- **Shared fused router top-k (#568, #567).** The Qwen3.5 decode-only Metal router kernel moved into `MLXLMCommon` and generalized for separate selection/score tensors while preserving winner order; now used by Qwen 3 MoE, OLMoE, Mixtral, Jamba and Granite MoE Hybrid. Prefill keeps the generic MLX path. Cross-dtype bitwise coverage plus per-model parity tests against each original router expression.
- **Compiled decode segments generalized to Qwen 3 Next (#569).**
- **Single-dispatch TurboFlash for short contexts (#520)**, with query grouping tuned for short decode (#570).
- **Qwen3.5 MTP speculative decoding (#351).**

### Tool calling
- **Parser hardening (#531).** Two real bugs. (a) `JSONValue.from` tested `as? Bool` before `as? Int`; `JSONSerialization` boxes scalars as `NSNumber`, and an `NSNumber` holding 0 or 1 bridges to `Bool` — so `{"limit": 1}` arrived as `{"limit": true}` in **every** parser that decodes a value as JSON (Gemma, Pythonic, XML function, GLM4, Kimi K2, MiniMax M2, Llama 3, Mistral, ATEM), breaking any integer-typed schema parameter. (b) Pythonic and Gemma argument splitting moved onto a shared `StructuredTextScanner`, so a value containing `)`, `]`, `,` or `:` survives intact — the lazy `\[(\w+)\((.*?)\)\]` regex used to lose everything from `)]` onward.
- **Rejected tool calls are generation events (#512, #538).** `Generation.rejectedToolCall(RejectedToolCall)` and `ToolCallProcessor.Output.rejectedToolCall` carry tool-call-shaped output that parsing or authorization refused, with `rejectedToolCallCount` on the decoder. Declared-tool authorization moved into `ToolCallProcessor.allowedToolNames`, so it applies to **every** parser instead of only `JSONToolCallParser`.
- **Gemma brace-form values (#557).** Gemma writes nested values as `{city: "Paris"}` — JSON except for unquoted keys, which `JSONSerialization` refuses, so an `object` parameter reached the tool as a string. Bare keys are now quoted and re-parsed; bare *values* deliberately are not (`{ok: yes}` has no JSON meaning).
- **Qwen 3.5 JSON tool-call fallback (#529)**, a `.qwen35` format with its own parser.
- **ATEM tool calling with Muse-Glimmer (#523)**, plus an Onyx stream adapter and tool-restart rule.
- **Protocol-aware thinking budget enforcement (#521).**

### New models & capabilities
- **Muse-Glimmer (#523)** — 30B agentic multimodal, 52-layer dense text transformer + 50-layer native-resolution ViT.
- **Helium / Kyutai (#555)**, **TranslateGemma (#348)** with its own chat template and a `ModelConfiguration.messageGenerator` override seam.
- **Reranker API (#375)** — shared request/result types, encoder rerankers, Jina listwise reranker, BGE/Jina registry wiring.
- **Video processing options (#534/#429)** — `UserInput.VideoProcessing` with `targetFrames` / `framesPerSecond`, threaded through `MediaProcessing.asProcessedSequence` and the VLM pipelines.
- **LoRA dropout and training mode (#541)**; **opt-in q4_0 lattice calibration in conversion (#507)**.

### Correctness fixes that matter to us
- **Weight files a safetensors index leaves out (#562).** `BaseLanguageModel.additionalWeightFiles` lets a model name sidecars its index omits, and — the part that reaches our users — loading now **falls back to every safetensors file in the directory when the index names a file that is not there**. Several `mlx-community/Qwen3-VL-*` uploads kept the index of their unquantized source repo, so they named shards the repo does not ship and loading found no weights at all (#554).
- **LFM2VL image token id read from the vocabulary instead of hardcoded 396 (#576).**
- **Qwen2.5-VL vision cuSeqlens accumulated across temporal slices (#509).**
- **Tied word-embedding (#532) and tied quantized Qwen3 MoE head (#490) sanitization.**
- **`LogitProcessor` copy semantics enforced for speculative decoding (#533)** — draft and verify passes now run on copied processor state so unaccepted tokens cannot pollute canonical state.

### Build / toolchain
- **`mlx-swift` requirement moved `0.31.4` → `0.31.6` (#484)** — "*.4 was missing new API that the current code calls*". That API is `MLXArray.maskFill(for:)` + the `DType.finfo` extensions from mlx-swift PR #429, used by `KVCache.swift` and `ThinkingBudget.swift`. **Our fork already carries it** as the additive #429 cherry-pick (`37b3ca1`) on top of the `0.31.4` base — see the dependency section below.
- Compiler warnings cleared from the library and both test targets (#594); a `CLAUDE.md` / `AGENTS.md` and an AI usage policy added upstream (#585).

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| **VLM warm-cache turns** | **Would have failed outright** without the app-side fix in R1 — `prepare` now fails closed on a warm cache with no `LMOutput.State` |
| Model load time | Concurrent byte-balanced weight loading, up to ~1.8x faster; no configuration change (#575) |
| Fork patch surface | **Zero** VLM models fork-patched — Qwen3VL and GlmOcr, the last two, retired (#475) |
| Qwen3-VL text turns | The inert all-ones mask is gone upstream, so the app's `sparseAttentionMask` veto can no longer be tripped by it (#549) |
| Qwen3.5 / MoE decode | Fused GDN projections, direct expert reduction, shared fused router top-k, TurboFlash short-context path (#572, #573, #568, #520, #570) |
| Tool calling | Integer arguments stop arriving as booleans; values containing `)]`,`:` stop being truncated; rejected calls are now an event we log (#531, #512) |
| Model loading robustness | `mlx-community/Qwen3-VL-*` uploads with a stale index now load instead of finding no weights (#562) |
| KV cache | A capacity is now honored on hybrid models instead of throwing — but we still do not set one, for a different reason (R5) (#514) |
| Dependency / PrismML | No fork move needed: the required 0.31.6 API is the #429 cherry-pick the fork already carries. `QuantizationTests` 5/5 green |

---

## Risk Assessment — **5 identified risks (1 high, 2 medium, 2 low)**

### R1 — Warm-cache VLM continuation fails closed (HIGH — fixed in this cycle)
PR #475 makes `QwenVL.continuationAnchor` throw `ContinuationStateError.missingState` when `cacheOffset > 0` and the model's M-RoPE anchor is absent from `LMOutput.State`. Three models call it: `MLXVLM/Models/Qwen3VL.swift`, `MLXVLM/Models/Qwen35.swift` (Qwen3.5-VL) and `MLXVLM/Models/GlmOcr.swift`. `ChatSession` threads that state turn to turn (`lmState = iterator.state`); **our path does not** — `predictVLM` calls `generateRecordingTokens(input:cache:…)` with no `state:`, and `MLXPromptCacheBox` holds only `[KVCache]` and the token ledger. Every turn after the first on those three models would therefore have thrown out of `TokenIterator.init` and surfaced to the user as a failed generation. Upstream pins the behavior in `Qwen3VLContinuationTests.testWarmContinuationWithoutStateThrows`.

*Fixed:* both `predictLLM` and `predictVLM` now catch `ContinuationStateError` specifically, invalidate the cache with reason `missingContinuationState`, and retry once at full prompt length. The anchor is the first thing `prepare` computes, so the failed attempt costs a template render rather than a prefill. Scoped to that typed error so a Metal OOM still fails the round instead of being retried at full length.

*Residual:* VLM warm-turn reuse is **off** for those three models — back to where it was before the 2026-08-24 fork commit. Threading `LMOutput.State` through the box would restore it; see Follow-ups.

### R2 — Concurrent weight loading raises peak memory during load (MEDIUM)
`#575` opens up to `clamp(cores, 4...16)` byte-balanced groups (min 256 MiB each) and evaluates them concurrently. The measurements are M4 Pro / NVMe; an iPhone has fewer cores, far less headroom and a jetsam ceiling rather than swap. Our pre-load admission check (`SystemMemoryHelper`, `helper/docs/device_ram.md`) sizes a *serial* loader's peak.
*Verify:* load the largest shipped MLX model on the smallest supported device with the memory HUD on, and compare peak against the pre-load estimate. If peak has moved, the estimate in `device_ram.md` needs a term for concurrent group residency.

### R3 — Tool-call argument typing changed for every parser (MEDIUM)
`#531` stops `NSNumber` 0/1 from bridging to `Bool`, so a schema-declared integer that previously arrived as `true`/`false` now arrives as `1`/`0`. This is a fix, but it changes the values our tools receive on a hot path, and any app-side code that came to depend on the buggy shape will change behavior. Combined with `#557` (Gemma brace-form objects now parse as objects rather than strings) and the structural scanner rewrite, three dialects changed their output types in one merge.
*Verify:* `ToolCallParserChainTests` plus one real tool round-trip per shipped MLX model with an integer or object parameter — `run_shell`-style integer limits and any tool with a nested-object argument.

### R4 — `cachedPromptTokenCount` reads 0 on our path (LOW)
`#559` attributes cache reuse *at the `ChatSession` boundary*, because the generation loop receives an already narrowed prompt and has no notion of a prompt cache. We drive `generate`/`generateRecordingTokens` directly, so `GenerateCompletionInfo.cachedPromptTokenCount` is 0 and `cacheEfficiency` is 0 for us regardless of how much prefix we actually reused. Nothing breaks — `consumeMLXStream(fullPromptTokens:)` already overrides `promptTokenCount` with the whole rendered prompt for the token tracker — but the new field must not be mistaken for a usable signal.
*Verify:* nothing blocking. Our `[MLX-KVREUSE] decision=…` line remains the authoritative reuse trace.

### R5 — The stated reason for never setting a KV capacity is now obsolete (LOW)
`resolveKVAndSampler` documented "any non-nil capacity makes ~12 models fail to generate" under the PR #453 contract. `#514` rewrote `newCache` in exactly those files onto `makeAttentionKVCache` / `makeSlidingWindowKVCache`, so a capacity is honored rather than rejected. The policy is unchanged — capacity stays nil — but for two different reasons that #514 does not address: `RotatingKVCache.isTrimmable` is `offset < maxCacheSize`, so every turn past the cap would fall to `notTrimmable -> rebuild` and re-prefill the whole prompt; and `keep: 4` rotates the system prompt and tool definitions out of anything longer than the cap.
*Verify:* the rationale comment was rewritten this cycle. No behavior change.

---

## Follow-ups
1. **Restore VLM prompt-cache reuse by threading `LMOutput.State` (R1).** `TokenIterator.state` is `public internal(set)` but `generate`/`generateRecordingTokens` consume the iterator into their `Task` and never hand it back, and `LMOutput.State` wraps `[String: Any]` and is not `Sendable`. Needs a fork-local seam surfacing the final state, plus a `state` slot on `MLXPromptCacheBox` invalidated in lockstep with the caches. Worth a design pass, not a drive-by.
2. **Re-measure the pre-load memory admission check against the concurrent loader (R2)** and update `helper/docs/device_ram.md` if peak moved.
3. **Round-trip one tool per shipped MLX model with an integer / nested-object parameter (R3).**
4. `helper/docs/mlx-swift.md` "Models currently patched" now reads **None** — keep it in sync on the next merge, and note that `chunkedVLMPrefill` survives only for `testcases/MLXVLMLongPromptTests.swift` and as the escape hatch for the next single-shot model upstream ships.
5. **Not adopted:** the variance-normalized KV cache (#329) is explicitly slower on decode and aimed at memory-bound long context; the reranker API (#375), LoRA dropout (#541) and q4_0 lattice calibration (#507) are training/retrieval features with no current consumer here.
