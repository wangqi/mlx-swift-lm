# mlx-swift-lm Upgrade — `tag-20260722` → `tag-20260810`

**Merged:** 2026-08-10
**Upstream base:** `ml-explore/mlx-swift-lm` main (32 upstream commits; PRs #470, #453, #502, #482, #448, #467, #468, #469, #146, #506, #401, #465, #488, #479, #481, #472, #462, #483, #322, #391, #347, #379, #460, #456, #463, #485, #480, #477, #478, #464, #458, #513)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

This upgrade brings 32 upstream commits. The single most important item for our iOS integration is **PR #470 (`PrefillParameters` + balanced chunking)**: upstream replaced the bare `windowSize: Int?` on `LanguageModel.prepare` with a `PrefillParameters` value carrying a step size, a chunking strategy, and a progress callback, and consolidated nine near-duplicate per-model chunk loops into one generic `PrefillParameters.forEachChunk` driver that runs **on every platform**. That driver now covers eight of the ten VLMs our fork was hand-patching for iOS, so those fork patches were deleted and the files are byte-identical to upstream again — only **Qwen3VL and GlmOcr** still carry the `#if os(iOS) … chunkedVLMPrefill … #else …` patch. Balanced chunking also cuts full prefill time ~9% at 32K with no accuracy change, and `chunkedVLMPrefill` itself now delegates to `forEachChunk`, inheriting cooperative cancellation, per-chunk autorelease pooling, and progress reporting for free.

---

## Highlights

### On-device / iOS memory & stability
- **Balanced prompt chunking, now the default (#470).** Prefill divides the prompt into the fewest near-equal chunks that respect the step-size ceiling, instead of a fixed stride plus a small remainder whose leftover forward costs ~3x per token at large KV length. Measured upstream on Qwen3.6-35B-A3B at 32K: 51.01s → 46.23s full prefill (~9%), decode unchanged, no accuracy regression. Our `n_batch` default is 512, the same ceiling the library uses, so the win applies without any configuration change.
- **Chunked prefill is now generic and cross-platform (#470).** `PrefillParameters.forEachChunk` owns the loop, cancellation between chunks, an autorelease pool per chunk, and progress. Eight VLMs (FastVLM, Pixtral, LFM2VL, Gemma3, Mistral3, Idefics3, Qwen25VL, Qwen2VL) stopped being fork-patched because upstream chunks them itself; see R1.
- **Qwen2.5-VL / Qwen2-VL windowed prefill + state-threaded warm continuation (#448).** `prepareContinuation` slices M-RoPE `positionIds` in lockstep with the embedding chunks and anchors rope deltas across turns, so the **image/video** path is chunked too — strictly better than the fork patch it replaced, which only chunked the text-only path.
- **Typed KV cache configuration and runtime reporting (#453).** `GenerateParameters.kvCache: KVCacheConfiguration?` centralizes capacity / strategy / compatibility behind one resolved plan, threaded through the autoregressive, speculative, MTP, guided, and wired-memory paths. Legacy `maxKVSize` / `kvBits` / `kvScheme` still work and resolve to the same plan with `compatibility: .allowPartial`. `kvCacheRuntimeReport(cache:configuration:)` reports, per layer, whether the requested strategy is active / pending / skipped and why (`.slidingWindow`, `.unsupportedShape`, `.boundaryProtection`, …) — the first way to observe that our `kvBits = 4` is inert under a `RotatingKVCache`.
- **MTP speculation stands down before the sliding cache wraps (#506).** A stream that crossed the sliding window kept drafting until the verify pass tripped a `slidingKvLen` precondition; the iterator now re-checks trim headroom each round. We do not use MTP, but the fix removes a hard-abort class from the shared iterator.
- **Olmo3 sliding-window cache actually used (#462).** `newCache(parameters:)` had a non-optional parameter, so it was an unused overload and `sliding_attention` layers got an **unbounded** cache. Cached-forward smoke tests now cover every model with a bespoke `newCache` or hybrid layout.

### Performance (Qwen3.5 / 3.6, the family our on-device defaults use)
- **Compiled decode traces (#467).** Decode runs through MLX compiled traces at three levels (per-MoE-block closure, per-layer trace, whole-step segment schedule). Token-identical over 108 A/B pairs. Decode throughput: MoE +7.5% short context / +3.7% at 8K; dense +1.7–3.5%.
- **Fused router top-k Metal kernel for decode (#469).** Replaces the argPartition/takeAlong/normalise chain (three serial dispatches + hazard barriers per MoE layer per token) with one bit-identical kernel. Decode +1.91% at 128 context, +0.47% at 8K; dispatches per token 1914 → 1827. Decode-only — prefill keeps the block-sort path.
- **GDN decode conv folded into the compiled step (#468).** At S == 1 the depthwise conv1d becomes elementwise multiply-adds that fold into the surrounding traced segment, removing a dispatch and a barrier per GDN layer per token. Bitwise identical (f32 accumulation, one rounding), CI-pinned.
- **Gated delta recurrence precision (#488).** Kahan compensated summation for the recurrent k-state dot product so low-order terms do not drift at long context; Metal reassociation/contraction disabled only inside that reduction.

### New models
- **Qwen3-VL-MoE (#322)** — MoE variant of the Qwen3-VL vision family.
- **DeepSeek-V2 / V2-Lite (#379)** — reuses the in-tree V3 MLA machinery; `q_lora_rank: null` (V2-Lite) now loads, and the double KV-cache update that corrupted attention past the first token is fixed.
- **Hunyuan dense V1 (#347)** — `hunyuan_v1_dense`, the architecture behind the Hunyuan-MT-7B / Hy-MT2-7B translation models; per-head QK RMSNorm after RoPE, DynamicNTKAlphaRoPE.
- **Nanbeige 4.2 (#460)** — a looped transformer: the decoder stack runs `effective_num_loops` times with shared weights, each pass owning its own slice of a `num_loops × num_hidden_layers` cache array.
- **Gemma 4 video input (#391)** — end-to-end video on the base `gemma4` VLM; frames run through the same vision tower and scatter onto `<video>` soft-token positions, with ≤32-frame ~1 fps sampling in the processor.

### New capabilities / API
- **`PrefillParameters` (#470).** `GenerateParameters.prefill` carries `stepSize`, `chunking` (`.balanced` default / `.remainder` legacy / `.unchunked` escape hatch), and `progress: (processed, total) -> Void`. `prefillStepSize` is deprecated and forwards. **Consumer:** `AIChatModelMLX.buildGenerateParameters` already sets `prefill.stepSize` from `n_batch`; `progress` is newly adopted for `[MLX-PERF]` prefill instrumentation.
- **`ChatConventionsProviding` everywhere; `ToolCallFormat.infer` / `ReasoningConfig.infer` deleted (#482, #502).** Every model declares its own tool-call format and reasoning config next to its definition; non-intrinsic conventions go through a new `ChatConventionsResolving` + `ChatConventionsRegistry` extension seam. Factory precedence: explicit `ModelConfiguration` value → registered resolver → the model's own declaration. **Consumer:** `AIChatModelMLX` reads `context.configuration.toolCallFormat`, which the factories now populate from the model — see R2.
- **GPT-OSS Harmony tool-call parser (#146).** A `.gptOSS` `ToolCallFormat` plus a protocol-neutral `TokenStreamDecoder` seam that streaming tool-call decoding now routes through. Harmony deliberately bypasses the app's `fallbackToolCallParser` (its token-level framing has no ambiguous parse to recover from).
- **Custom `LogitProcessor` injection (#401).** `GenerationComponents` threads a `@Sendable logitProcessorFactory` through `TokenIterator`, the speculative/MTP iterators, `ChatSession`, and the parameters-driven `generate` functions, chained after the built-in `PenaltyProcessor` (matching Python mlx-lm ordering). Additive; empty components reproduce prior behavior.
- **Multi-round tool calling in MLXFoundationModels (#456).** Prior tool calls/results are replayed into the prompt and the tool path stays active each round.

### Correctness fixes
- **Streaming detokenizer dropped characters on non-append-only decodes (#465).** `NaiveStreamingDetokenizer.next()` diffed by character count, which assumes `decode()` is append-only — SentencePiece is not (Gemma rewrites whitespace at the append boundary), so a structural JSON comma was silently dropped. Now diffed by common prefix. Affects every Gemma/SentencePiece model's streamed text, not just guided generation.
- **LFM2 tool-argument parsing (#481).** `PythonicToolCallParser` truncated object values at the first comma and never recovered the real args from a schema-style wrapper (`get_weather(properties={…})`). Argument splitting is now bracket/brace/quote-aware, object/array values parse as JSON, and a single recognized wrapper key is unwrapped. GLM-4-9B-0414's markerless `funcname\n{json}` shape is documented as unsupported and its end-to-end test disabled.
- **Gemma 3n Boolean attention masks (#479).**
- **Structured `ChatSession` continuations (#472)**, plus documented cache reuse across the chat APIs.
- **Linux build breaks in MLXLMCommon / MLXGuidedGeneration (#483)** — an `autoreleasepool` shim, a per-module `Logger` shim with the full level set, and `-lc++` scoped to Apple platforms. Inert on our platforms; the `-lc++` scoping is the only line that touches our `Package.swift`.

### Build / toolchain
- **No dependency move.** Upstream still pins `mlx-swift` `.upToNextMinor(from: "0.31.4")`; our fork keeps the local path dep. The only `Package.swift` change in this range is `.linkedLibrary("c++", .when(platforms: [.macOS, .iOS, .visionOS, .tvOS]))`. PrismML patch untouched.

### Tests
- New suites: `PrefillParametersTests`, `KVCacheConfigurationTests`, `KVCachePlanBenchmark`, `CachedForwardSmokeTests`, `ChatConventionsTests`, `Qwen25VLContinuationTests`, `Qwen35CompiledDecodeLifecycleTests`, `Qwen35GDNDecodeBitwiseTests`, `Qwen35RouterTopKBitwiseTests`, `Qwen3VLMoETests`, `HarmonyFrameParserTests` / `HarmonyOutputRouterTests` / `HarmonyToolRestartRuleTests` / `HarmonyChatSessionRoundTripTests`, `StreamingDetokenizerTests`, `DeepseekV2Tests`, `HunyuanTests`, `NanbeigeTests`, `GLM4MoERoutingTests`, `Gemma3nMaskTests`, `Gemma4VideoInputTests`, `PromptCacheReusePolicyTests`.
- Gemma4 chunk-invariance oracles fixed for TF32/NAX flakiness (#485): synthetic models cast to f16, initializer weights pinned with `withRandomState`, max-abs-diff comparison. The chunking logic was correct; the oracle was not.
- Integration-test CI scoped down and moved to a nightly cron with a tracking issue (#480, #477, #478, #464, #458, #513).

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Prefill throughput | Balanced chunking is the default — ~9% faster full prefill at 32K, no accuracy change (#470) |
| Fork patch surface | 8 of 10 VLM `chunkedVLMPrefill` patches deleted; only Qwen3VL + GlmOcr remain (#470, #448) |
| Qwen2.5-VL / Qwen2-VL images | Image/video prefill is now chunked and rope-anchored across turns, not just the text-only path (#448) |
| Qwen3.5 / 3.6 decode | +1.7–7.5% decode from compiled traces, plus ~+0.5–1.9% from the fused router kernel and the folded GDN conv (#467, #469, #468) |
| Prefill observability | `prefill.progress` gives per-chunk `(processed, total)` — first direct measurement of where TTFT goes on a long prompt (#470) |
| KV cache | Typed configuration + a per-layer runtime report that names why a strategy was skipped; legacy fields unchanged (#453) |
| Streamed text | Gemma/SentencePiece models no longer silently drop characters at the append boundary (#465) |
| Tool calling | Format resolution moved from `model_type` prefix matching to per-model declarations; unregistered types now resolve to `nil` (degrading to `.json`) instead of matching by prefix (#502) |
| Dependency / PrismML | No `mlx-swift` / `mlx-core` version move — PrismML patch unaffected |

---

## Risk Assessment — **4 identified risks (2 medium, 2 low)**

### R1 — Eight VLM prefill paths changed owner in one merge (MEDIUM)
The recurring chunked-prefill overlap, at its widest yet. Upstream replaced `prepare(_:cache:state:windowSize:)` with `prepare(_:cache:state:prefill:)`; where the new `forEachChunk` driver covers a model, the fork's iOS branch was deleted (FastVLM, Pixtral, LFM2VL, Gemma3, Mistral3, Idefics3, Qwen25VL, Qwen2VL). Two of those — Qwen25VL and Qwen2VL — also swapped a fork patch that chunked only the text path for upstream's `prepareContinuation` that chunks the image path too. Static analysis says this is strictly better; the runtime path on device is nonetheless new for eight models.

The sharp edge here is not the conflicts — it is the files that **did not** conflict. `Gemma3.swift` and `Mistral3.swift` auto-merged cleanly into non-compiling code (new `prefill:` signature, body still passing an undefined `windowSize`) with no marker to warn you. `swift build` targets macOS and never compiles the `#if os(iOS)` branch where the fork patch lives.
*Verify:* build **both** schemes; grep every remaining `chunkedVLMPrefill` caller; run `testcases/MLXVLMLongPromptTests.swift` (updated for the `prefill:` signature in this cycle) on device against a real Qwen3VL checkpoint, plus a manual long-prompt and multi-turn-with-image smoke test on Qwen2.5-VL.

### R2 — `ToolCallFormat.infer` deleted; formats now resolved per model (MEDIUM)
`ToolCallFormat.infer(from:configData:)` and `ReasoningConfig.infer` no longer exist. Formats come from `ChatConventionsProviding` declarations resolved by the factories inside `_load` (both `loadContainer` overloads call it, so our local-directory loads do resolve). Upstream deliberately tightened behavior: prefix matching is gone, so **unregistered** model types (`lfm2_5`, `glm4_5`, `qwen3_next_moe`, `mistral3_text`) resolve to `nil`, and `nemotron_labs_diffusion` no longer reports `.xmlFunction`. In `AIChatModelMLX`, `modelConfiguration.toolCallFormat ?? .json` means a failed resolution degrades **silently** to JSON rather than erroring — a model that used to match by prefix will now quietly parse with the wrong format.
*Verify:* the `[MLX-LLM] toolCallFormat=…` / `[MLX-VLM] toolCallFormat=…` log line already prints the resolved format on every generation. Check it for each shipped MLX model with tools enabled — especially any LFM2 / GLM / Mistral 3 variant — and register a `ChatConventionsResolving` resolver if one resolves to `nil(default:.json)` when it should not.

### R3 — Streaming detokenizer diff changed for every model (LOW)
`NaiveStreamingDetokenizer.next()` now diffs by common prefix instead of character count (#465). Identical output for append-only (byte-level BPE) tokenizers; for SentencePiece it stops dropping characters. Our streamed text goes straight into `process_predicted_str`, so the change is visible in chat output for Gemma-family models — as a fix, but it is a behavior change on a hot path.
*Verify:* `StreamingDetokenizerTests` (model-free) plus one Gemma 3 / Gemma 4 chat with a multi-line, whitespace-heavy reply.

### R4 — New model families are untested on device (LOW)
Qwen3-VL-MoE, DeepSeek-V2, Hunyuan dense V1, Nanbeige, and Gemma 4 video all ship with upstream unit tests but none is a default on-device model here. They only affect users who add such a checkpoint. Gemma 4 video is the one worth noting: our `predictVLM` deliberately feeds video as pre-sampled `.ciImage` frames rather than `UserInput.Video`, so the new `<video>` soft-token path does not engage — behavior for existing users is unchanged.
*Verify:* nothing blocking; add the architectures to `mlxSwiftSupportedModels` (done) and revisit if a Gemma 4 video checkpoint is shipped.

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`) — the only way to compile the remaining `#if os(iOS)` fork branch.
2. Run `testcases/MLXVLMLongPromptTests.swift` on device for R1 (Qwen3VL long prompt + Qwen2.5-VL multi-turn-with-image).
3. Watch the `toolCallFormat=` log line on every shipped MLX model with tools enabled (R2); register a `ChatConventionsResolving` resolver for anything that degrades to `nil(default:.json)`.
4. `helper/docs/mlx-swift.md` "Models currently patched" now reads **Qwen3VL and GlmOcr only** — keep it in sync on the next merge.
5. **Not adopted, worth a plan:** upstream's prompt-cache reuse (`PromptCacheReusePolicy`, `PromptCacheTurn`) lives inside `ChatSession` and is `internal`, so it is unreachable from the `generate(input:parameters:context:)` path the app drives. Every turn of a chat therefore re-prefills the whole history. This is the largest remaining MLX latency win available to us and needs its own design pass (our `PromptAssembler`/CONTEXT.md pipeline owns prompt construction, so adopting `ChatSession` wholesale is not a drop-in).
