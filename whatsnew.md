# mlx-swift-lm Upgrade — `tag-20260831` → `tag-20260918`

**Merged:** 2026-09-18
**Upstream base:** `ml-explore/mlx-swift-lm` main @ `c6446cf` (17 upstream PRs: #620, #515, #548, #584, #597, #611, #615, #613, #616, #602, #589, #605, #471, #599, #579, #591, #596)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

A small upgrade by commit count — 17 upstream PRs against the previous cycle's 54 — but a concentrated one. The single most important item for our integration is **PR #548 (bounded cross-dialect tool-call recovery)**, which rewrote the whole streaming tool-call layer: a new `TextToolCallRecoveryScanner` now sits in **front of** the selected parser, chunks are re-split at dialect-signal boundaries before they reach the native state machine, `ToolCallPolicy` arrives on `GenerateParameters`, and arguments are normalized and schema-checked at a single common admission boundary. All six merge conflicts were in that layer, and all three fork-local tool-call patches — `fallbackParser`, `pendingOutput` invisible-start-tag buffering and the `JSONToolCallParser` XMLFunction fallback — had to be re-seated on top of it rather than merged alongside it.

The second item looked, on inspection, like a regression and turned out to be the opposite. **PR #620 moves `MLX.Memory.clearCache()` onto the first generated token of every generation**, right after prefill — mechanically the per-generation cache clear this app deliberately deleted in 2026-07-26 after measuring a ~2x decode cost. It was measured rather than assumed (harness and numbers in R1): on a 256-token prompt / 48-token generation loop with a 1 GB `cacheLimit`, **upstream's cadence is 7-13% FASTER**, and the buffer pool settles at ~90 MB instead of ~900 MB. The 2026-07-26 finding stands but does not transfer — clearing *before* prefill destroys the pool decode is about to reuse, while clearing *after* prefill sheds prefill-shaped buffers decode cannot reuse anyway. **Do not fork-patch #620.**

Nothing in this range moves the `mlx-swift` requirement, adds a model architecture, or touches the VLM prefill surface. `Package.swift` is byte-identical between `ad00de5` and `c6446cf`.

---

## Highlights

### Tool calling (the layer our fork invests in most)
- **Bounded cross-dialect tool-call recovery (#548).** `TextToolCallRecoveryScanner` recognizes `<tool_call>`, `<|tool_call>`, `<function=` and `[TOOL_CALLS]` regardless of which dialect the model's own parser advertises, and promotes a foreign-dialect call only when it names an **exactly declared** tool. It is constructed only when `tools` is non-nil **and** `allowedToolNames` is non-empty, so a tool-free generation keeps the old path verbatim. Reasoning spans (`<think>`, `<thinking>`, `[THINK]`), JSON string values and Markdown code spans are classified as `protectedText` and never re-scanned — a call hidden inside reasoning or a code fence cannot execute.
- **A common admission boundary for every call (#548).** `ToolArgumentNormalization` coerces union/combinator-typed arguments from their wire value, then `ToolSchemaValidator` runs a three-state evaluator that rejects only **proven** schema violations; unsupported assertions fail open. Applied identically to generic, Harmony and Onyx calls. `ToolCallValidationPolicy.strict` is opt-in; the default stays permissive.
- **Native XML calls validated against the shared Qwen grammar (#548).** `XMLFunctionParser` was rewritten onto `QwenXMLPayloadScanner`: the function close is the *structural* close rather than the first textual `</function>`, every `<parameter=` must close, and nothing but whitespace may trail the payload. A truncated frame now yields `nil` instead of a partially populated call — structural validity no longer depends on whether the schema declares `required`.
- **False openers no longer swallow leading text (#548).** `scanTaggedStart` replaced the anchored `partialMatch` branch: a disproven opener rules out only that candidate, not the rest of the chunk, and the scan walks to the next start character instead of flushing the whole buffer. `<tool_call>` frames close only on a structurally complete payload, so a literal `</tool_call>` inside a string argument can no longer truncate a frame and expose its suffix as new input.
- **Oversized attempts are quarantined, not re-scanned (#548).** A tool-call buffer past 64 KiB is rejected with `.resourceLimitExceeded` and the processor enters `quarantiningOversizedToolCall` until EOS, so resuming mid-syntax cannot turn argument data into a new call.
- **New observability:** `ToolCallProcessor.recoveryEvents` / `recoveredToolCallCount`, surfaced through `TokenStreamDecoder` and onto `GenerateCompletionInfo.recoveredToolCallCount`.

### Memory & generation loop
- **`clearCache()` on the first generated token (#620).** `TokenIterator.next()` incremented `tokenCount` before testing `% 256`, so the first clear landed at token 256 and a generation shorter than that never cleared at all. The increment moved after the test, matching mlx-lm: the pool is now cleared at token 0 — immediately after prefill — and every 256 tokens thereafter. Upstream's stated motivation is unbounded pool growth across repeated short requests. **This app already bounds the pool with `MLX.Memory.cacheLimit`** (64 MB–1 GB by RAM tier, `resolveMemoryBudget`), so we take the cost without the benefit. See R1.
- **Generation no longer parks a cooperative thread (#611).** `GenerationWorker` is an actor with a custom `DispatchSerialQueue` executor; `generateLoopTask` runs each iteration on it, keeping all evaluation and cleanup on that executor instead of blocking a Swift concurrency worker for the length of a generation.
- **Weight loading suspends instead of blocking (#579).** A new `async loadWeights` overload hops to a global queue and suspends the caller; every model factory now uses it. The synchronous overload remains for `convert`. Swift prefers the async overload inside an `async` function, which is why #605 had to add `await` to five `IntegrationTesting` call sites that had silently stopped compiling.

### Prompt cache
- **Append-only media turns can reuse the cache (#515).** New `PreparedInputSplitting` protocol: a model that computes each media item's features independently can carve a media-carrying suffix at a token boundary. `AppendOnlyMediaRule` fires when a turn adds new media to an unchanged transcript and no speculative decoding is configured; `ChatSession` asks the model to split, verifies the returned tokens against the boundary, and downgrades to `.rebuild` otherwise. **`Qwen25VL` is the only conformer** — its vision mask isolates each frame. `Qwen2VL` attends across images and deliberately does not conform. Video, temporal grids, audio, precomputed position ids, non-uniform masks and boundaries inside a media block all refuse.
- **`RotatingKVCache.trim` is wrap-aware (#584).** Trimming a wrapped ring previously left dead rows in the logical timeline. Trim now linearizes the ring to temporal order and discards the newest rows, clamped to the non-pinned span. `offset == fill` is decoupled by tracking live rows via `idx` plus an explicit `wrapped` flag, serialized as a 7th `metaState` value and backward-compatible with 5- and 6-value legacy states. `isTrimmable` keeps its strict `offset + positions < maxSize` semantics for exact callers.

### Performance
- **ParoQuant: MoE support and a much faster path (#471).** Standalone `PairwiseRotation` module plus `RotateSwitchGLU` for MoE PARO models; `gate_up` rotation moved **before** the expert gather/sort, cutting row-rotation overhead by `1/topK`; the Metal rotation kernel rewritten for `groupSize == 128` to run in a single simdgroup with `simdgroup_barrier` (generic fallback otherwise) for up to 2x; the six-kernel GatedDelta elementwise decay chain compile-fused into one dispatch; and converted weights cached to `prepared_checkpoint.safetensors` with self-healing validation manifests, cutting warm-load time.
- **Gemma 4 VLM logit softcapping fused (#615).** `gemma4LogitSoftcap` promotes float16/bfloat16 logits to float32 before tracing and runs `tanh(logits / cap) * cap` as one compiled, shapeless kernel.
- **Module weights declared as compile state (#589).** Compiled decode paths now declare their module weights as compile state, so a weight update invalidates the trace instead of being silently frozen into it. This is the change that added `CompiledTrace.swift` and the `CompileOverloads.swift` `@Sendable`-bodied `compile` matrix — see R5.

### Correctness fixes
- **Streaming detokenizer measures the common prefix in Unicode scalars (#613).** It previously measured in `Character`s, so a token appending a combining scalar (U+FE0F, a ZWJ, an accent) to the previous character re-emitted the whole merged grapheme cluster: a ZWJ flag sequence streamed as its base flag repeated, a quote followed by a variation selector as two quotes. Four new tests stream a ZWJ flag, a variation selector after an ASCII quote, a combining accent, and a variation selector split across two tokens.
- **`Gemma4Text.loraLayers` returns the decoder layers (#602),** matching Gemma3Text / Qwen35 / Llama, so adapters targeting `mlp.*` no longer fail `LoRAContainer.load` with unhandled keys.
- **FoundationModels prompt token counts restored (#591).** The per-response usage update the adapter sends was removed in July because the beta SDK declared a call the shipping system library did not provide; it is back, confirmed against the Xcode 27 beta 6 SDKs. Callers previously read zero prompt tokens while completion tokens still counted, so totals looked plausible.

### New capabilities / API
- **Configuration-based LoRA metadata discovery (#597)** — `loraMetadata(configurationData:)` on both the LLM and VLM factories returns a model's LoRA metadata without loading weights.
- **Falcon-H1 encoder surface at `@_spi(FalconH1Encoder)` (#596)** — `FalconH1ModelInner.callAsFunction(inputsEmbeds:cache:)` is the new seam, mirroring the Gemma 3/4 exposures, for clients that build their own embedding (the motivating case is a DualAR TTS model whose slow stack takes a text embedding summed with ten codec-codebook embeddings).
- **Gated-delta recurrence is differentiable (#616)** — `gatedDeltaUpdate` gains a `useKernel` flag so training falls back to the differentiable ops path (the fused Metal kernel has no VJP and aborted on backward), with 16-step chunked activation recomputation via `CustomFunction`. **Inference is unchanged** and still uses the fused kernel.

### Tests
- Foundation Models fixtures hardened (#599): empty `catch {}` drains that could pass on a read failure replaced with a single awaited helper; `@unchecked Sendable` stub classes converted to structs or moved onto `Mutex`; an availability `guard` that could never fire replaced by a compile-time annotation.
- New suites: `ToolCallProcessorStreamingTests`, `ToolCallRecoveryRegressionTests`, `TextToolCallRecoveryTests`/`Benchmark`, `ToolSchemaValidatorTests`, `ToolCallPolicyTests`, `ToolArgumentNormalizationTests`, `XMLFunctionParserStrictnessTests`, `TokenIteratorClearCacheTests`, `QwenVLPreparedInputSplitTests`, `CompiledTraceTests`, `CompiledDecodeWeightUpdateTests`, `Gemma4FusionTests`, `Gemma4LoRATests`, `FalconH1EncoderAccessTests`, `GenerationExecutionTests`, `ParameterCoercionTests`, `LoRAModelMetadataTests`.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| **Decode throughput** | `clearCache()` now fires on the first generated token of every generation. **Measured 7-13% faster** on the short-round agent shape, pool 90 MB vs 900 MB (#620). R1 |
| **Tool calling** | A recovery scanner runs ahead of the native parser on every tool-bearing MLX generation, re-splitting chunks at dialect boundaries. Three fork patches re-seated on top of it; five silent breakages fixed during the merge (#548). R2 |
| Streaming text | ZWJ emoji, flags, skin-tone sequences and variation selectors stop repeating mid-stream — a visible fix in `IncrementalMarkdownParser` output (#613) |
| App responsiveness during load | Model loads suspend instead of parking a cooperative thread; generation runs on its own serial executor (#579, #611) |
| VLM prompt cache | **No change for our catalog.** `PreparedInputSplitting` conforms on `Qwen25VL` only, which we do not ship, and the rule lives in `ChatSession`, which this app does not use (#515). R3 |
| KV cache | `RotatingKVCache` trim correctness — unreachable here: `resolveKVAndSampler` requests no capacity, so no rotating cache is ever built (#584) |
| Gemma 4 vision | Logit softcapping fused into one float32 kernel; `gemma-4-e2b-it-4bit` is in the shipping catalog (#615) |
| ParoQuant | Faster rotation kernel and disk-cached prepared checkpoints — no ParoQuant model ships today, but the cache writes a new file into the model directory (#471). R4 |
| `mlx-audio-swift` | **Broke the iOS build.** `CompileOverloads.swift` shadows `MLX.compile` in any file importing `MLXLMCommon` (#589). R5 — fixed |
| Dependency / PrismML | **No move.** `Package.swift` byte-identical across the range; `mlx-swift` stays `0.31.4` (`dc43e62` + `37b3ca1`), core `0.31.1` (`ce45c52`) |

---

## Risk Assessment — **5 identified risks (1 medium, 3 low, 1 resolved by measurement)**

### R1 — `clearCache()` on the first generated token — measured, and it is a win (RESOLVED)
`TokenIterator.next()` now calls `MLX.Memory.clearCache()` when `tokenCount % 256 == 0` **before** incrementing, so the first clear lands at token 0 — immediately after prefill. `AIChatModelMLX.buildGenerateParameters` carries a standing counter-rationale: *"The former per-generation clearCache() is deliberately gone: dumping the warm buffer pool before every generation forced per-token allocation misses (the ~2x decode slowdown)."* That made #620 look like a silent re-introduction of a regression this project had already paid for, so it was measured rather than argued.

*Harness:* a temporary interleaved A/B in `MLXLMTests` on `Qwen3.5-4B-MLX-4bit` (the same model as the 2026-07-26 finding), driving `TokenIterator` directly with a stub tokenizer — 256-token prompt, 48 generated tokens, prefill excluded from the timing, `MLX.Memory.cacheLimit` pinned to 1 GB to match what `resolveMemoryBudget` gives a 12 GB-class iPhone. A/B alternates **inside one process** and reports medians, because this Mac loses ~3x throughput across consecutive `xcodebuild` runs and any sequential comparison is noise.

*Result, three independent readings:* upstream's cadence beat the patched-out variant by **+12.6%, +6.9% and +11.2%** (e.g. 59.6 vs 52.9 tok/s in the least-throttled reading). `MLX.Memory.cacheMemory` after the loop: **~65-95 MB with the clear, ~820-955 MB without** — the pool otherwise fills to the `cacheLimit` with prefill-shaped buffers that decode never reuses.

*Why the 2026-07-26 finding does not transfer:* that one cleared **before** prefill, destroying the pool decode was about to draw from, and it did so with a 20 MB `cacheLimit` that made every subsequent allocation a miss. #620 clears **after** prefill, shedding exactly the buffers decode cannot reuse and leaving the allocator a small, well-matched pool.

*Action:* none. **Do not fork-patch `Evaluate.swift`.** The harness was removed after measuring; re-create it from this description if the cadence changes again. The one thing still worth doing is confirming the direction on real hardware — an iPhone has a much smaller `cacheLimit` tier (64-256 MB on 6-8 GB devices), where the pool is less able to absorb prefill buffers in the first place and the win should be smaller, not negative.

### R2 — The tool-call layer was rewritten under three fork patches (MEDIUM)
PR #548 replaced the `.potentialToolCall` branch, the chunk entry point and the EOS path that all three fork-local tool-call patches attach to. The merge resolution had to re-seat each one, and **five breakages were silent** — they compiled and simply stopped applying:

1. `generateRecordingTokens` (fork-added) never received the new `toolCallPolicy`, so recovery silently ran on defaults there while the upstream sibling honored the caller's `GenerateParameters`.
2. The recovery pass-through fast path emitted `.normal` text directly, bypassing `pendingOutput` buffering for tagged-only formats and leaking the part of a tool-call body carrying none of the scanner's interesting bytes.
3. The legacy `processEOS` never drained `pendingOutput` — the fork wired the drain only into `processEOSOutputs`. Any `processChunk`/`processEOS` consumer lost every held chunk at end of stream.
4. `pendingOutput` was held past a *confirmed* start tag, emitting pre-call text after the call (`<note>hi</` + call + `note>after`).
5. The hold covered **every** `.normal` chunk. Invisible while chunks came straight from the detokenizer; not invisible once the recovery scanner splits a chunk at each signal boundary, which made `"before <|tool_call_start|>[…]"` arrive as a bare `"before "` that was withheld to EOS.

All five are fixed and the hold is now narrowed to chunks that actually open a payload (`{` or `[`).

*Verify:* `ToolCallParserTests` (84), `ToolCallParserChainTests` (23), `Gemma4ToolCallParserTests` (7) — all green. Beyond the suites, one live tool round per shipped MLX model that tool-calls, with `[MLX-LLM] toolCallFormat=` in the log: LFM2.5 (`.lfm2`, the invisible-start-tag case), Qwen3.5 (`.qwen35`, the XMLFunction fallback case), Ternary-Bonsai (the `{`-opening newline case), Gemma 4 (`.gemma4`).

### R3 — `PreparedInputSplitting` delivers nothing to this app (LOW — do not build on it yet)
`vlmBlockedReason` returns `"preparedMedia"` for every image or video turn, so a picture conversation re-prefills the whole transcript and re-runs the vision tower over every cached image — exactly the cost #515 was written to remove. It is tempting to mirror `AppendOnlyMediaRule` into `MLXPromptCacheReuse`. Two facts say not yet: the rule lives in `ChatSession`, which this app does not use, so nothing arrives for free; and **`Qwen25VL` is the only conformer**, while the shipping VLM catalog is LFM2.5-VL-1.6B, LFM2.5-VL-3B, GLM-OCR, gemma-4-e2b-it and Ministral-3 (Pixtral). The work would be a fourth `MLXPromptCacheDecision` case, a media-aware ledger and a `splitPreparedInput` call — against zero shipped models.
*Verify:* nothing. Revisit when a conforming model enters the catalog, or when upstream conforms LFM2VL / Gemma4.

### R4 — ParoQuant prepared checkpoints write into the model directory (LOW)
`#471` caches converted weights to `prepared_checkpoint.safetensors` beside the model, in the background, with a self-healing validation manifest. No ParoQuant model ships today, so this is latent — but when one does, a file appears in a directory whose size the app reports (`SystemMemoryHelper.mlxModelFileSizeBytes`, `StorageSectionView`) and whose completeness it gates on `.hfmanifest.json`. A stray large file in there inflates the reported model size and the `estimatedMLXMemory` load figure derived from it.
*Verify:* only if a ParoQuant model is added to `helper/models_*.json`. At that point check `mlxModelFileSizeBytes` against the intended weights and decide whether to exclude the prepared checkpoint.

### R5 — `CompileOverloads` shadows `MLX.compile` for every downstream importer (LOW — fixed)
`#589` added a complete `compile` overload matrix in `MLXLMCommon` whose bodies are `@Sendable`, deliberately so that a Module or `MLXArray` cannot be captured into a trace. They are public and unqualified, so in any file importing both `MLX` and `MLXLMCommon` they win overload resolution over `MLX.compile`. `thirdparty/mlx-audio-swift`'s `ParakeetModel.swift` does exactly that and stopped compiling — four `SendableClosureCaptures` errors on `self`, `decoder`, `joint` and `blankTokenArray`.
*Fixed:* both call sites qualified to `MLX.compile`, tagged `// wangqi modified 2026-09-18`. Note that upstream's diagnostic is arguably right about that code — those traces do freeze module weights in — so the qualification preserves today's behaviour rather than endorsing it.
*Verify:* iOS and macOS schemes both BUILD SUCCEEDED.

---

## Follow-ups
1. **Confirm R1's direction on device.** Measured +7-13% on macOS with a 1 GB `cacheLimit`; an iPhone tier is 64-256 MB, so the effect should shrink rather than invert. One Protocol Inspector session, five short agent rounds, `[MLX-PERF] gen done` decode t/s against `tag-20260831`.
2. **Live tool round per tool-calling MLX model (R2)** — LFM2.5, Qwen3.5, Ternary-Bonsai, Gemma 4.
3. **Consider surfacing `recoveredToolCallCount`.** `GenerateCompletionInfo` now reports how many calls were promoted by cross-dialect recovery rather than parsed natively. A non-zero count on a shipped model is a signal that model's declared `toolCallFormat` is wrong — a diagnostic the app has never had. One line in the `[MLX-PERF] gen done` log.
4. **Stale comment in `buildGenerateParameters`** still cites `ToolCallFormat.infer()`, deleted upstream in `tag-20260810`. Formats now resolve per model class via `ChatConventionsProviding.toolCallFormat`.
5. **Not adopted:** `ToolCallValidationPolicy.strict` (the permissive default rejects only proven violations and fails open on unsupported assertions — the right posture for a local model whose schema adherence varies); `loraMetadata` (#597) and the Falcon-H1 encoder SPI (#596) have no consumer here; gated-delta training (#616) is training-only and inference is unchanged.
