# mlx-swift-lm Upgrade — `tag-20261030` → `tag-20261113`

**Merged:** 2026-11-13
**Upstream base:** `ml-explore/mlx-swift-lm` main, 25 upstream commits (PRs #528, #551, #581, #608, #637, #692, #711, #715, #724, #729, #743, #747, #750, #754, #761, #763, #765, #766, #769, #774, #778, #784, #786, #787, #790)
**Old fork tip:** `0a5ff28` (version 20261030) · **New:** `c041e0e` (merge of upstream/main)
**Dependencies:** no move. `Package.swift` and `Package.resolved` are unchanged, so the PrismML 1-bit/2-bit patch on mlx / mlx-swift is untouched.
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

This merge brings in 25 upstream commits. For our iOS integration, the main gain is lower load memory. #711 stops
the loader from reading checkpoint components that a model does not have. For us that is the Gemma 4 audio
encoder and the Qwen 3.5 MTP head. #711 also releases the source tensors before the model is materialized. On
Qwen 3.5, the fused GatedDeltaNet input projections used to keep their 1.3 GB of sources in the buffer cache.
Two dtype fixes keep activations out of float32 on paths we ship. #766 covers float16 VLMs on image prompts.
#754 covers Nemotron-H, and with it our Nemotron-3-Nano-4B row. LFM2 has been rewritten for LFM2.5 (#528) and
absorbs both of our LFM2 fork patches. LFM2's convolution layers now use a trimmable cache. That changes
what our prompt-cache reuse can do on the five LFM2.5 rows (R2). LFM3 (#750) is new. The MiniCPM5 tool parser
moved upstream (#637), and the fork's copy is gone. Nothing here is a silent ship-blocker. No app source change
was forced: there is no name clash, no deprecated loader is used, and no exhaustive switch breaks. The
regression gate below decides whether this ships.

---

## Highlights

### On-device / iOS memory & stability
- **Skip checkpoint components a model does not have (#711, #790).** Each model family declares a `CheckpointLayout`.
  The loader reads a part on demand, with the model, or never. Upstream measured these drops on an M4 Pro:
  gemma-4-e4b LLM 5.43 → 4.49 GB after load, and Qwen3.5-9B-8bit prefill peak 14.04 → 11.99 GB.
  `loadWeights` releases the checkpoint before it materializes the model, and
  `materializeModelForInference` clears the buffer cache. Rows that benefit: `gemma-4-e2b-it-4bit`, which no
  longer reads its audio encoder, and all `Qwen3.5-*-MLX-4bit` rows, which drop the fused GatedDeltaNet sources
  and the MTP head. #790 fixes #711's logger so the build compiles (`MLXLogger`).
- **VLM image prompts stay in the model dtype (#766).** On Qwen2-VL and Qwen2.5-VL, float32 M-RoPE cos/sin made
  image prompts run every layer and the KV cache in float32. FastVLM did the same through float32 pixels, and
  Mistral3 through a bfloat16 cast of float16 features. Those prompts had twice the KV bytes and a slower
  decode. Our `Ministral-3-3B` row is a bfloat16 checkpoint, so its output does not change. The fix matters
  for any float16 VLM a user imports.
- **Nemotron-H Mamba activations stay in the input dtype (#754).** The gated RMS norm passed a float32 weight, so
  the residual stream became float32 after the first Mamba layer. Our `NVIDIA-Nemotron-3-Nano-4B-4bit` row
  (bfloat16) now runs with less activation memory and a faster decode. Its numerics change slightly.
- **RotatingKVCache keeps the pinned prefix in multi-token masks (#747).** This applies only when `keep > 0`, that
  is, when a `maxKVSize` capacity is requested. The app never sets one (`maxKVSize` is always nil), so the app
  is not affected.
- **MTP speculative decoding in `ChatSession` (#581).** Qwen 3.5 and Gemma drafters are resumable across turns and
  tool restarts. #724 batches the greedy verification into one GPU readback per round (Qwen3.5-4B-4bit:
  27.7 → 28.5 tok/s on M2), and #774 reports log probabilities from the speculative iterators. The app drives
  `generate` directly rather than `ChatSession`, so none of this is used (see Opportunities).

### New models
- **LFM2.5 (#528):** dense and MoE LFM2.5, mixed-precision quantization, a hybrid cache with a
  `RewindableConvolutionCache` (rewinds up to 64 positions), scoped variants, LFM2.5 DSpark speculative drafter,
  and faster quantized MoE route grouping. LFM2VL fails with a thrown error when the vocabulary has no `<image>`
  token. It used to fall back to id 396, which is "ab" in the LFM2.5 vocabulary. Both of our LFM2.5-VL rows
  have `<image>` in their vocabulary.
- **LFM3 (#750):** `model_type: "lfm3"` text model, always-on thinking (`enable_thinking` honoured), tool-call
  format `.xmlFunction`. `lfm3_vl`, `lfm3_omni` and `lfm3_audio` are **not** registered.
- **MiniCPM5 tool-call parser upstream (#637):** `ToolCallFormat.miniCPM5` (raw value still `"minicpm5"`),
  `MiniCPM5ToolCallParser`, CDATA-aware.
- **EmbeddingGemma 2:** image orientation fix and batched text (#692), soft tokens per batch row (#729),
  `ModelMemoryReporting` (#787), x86_64 build fix (#763). There is a new `MultimodalEmbedding` contract and factory.
- **Qwen3.5 VLM YaRN (#761):** the VLM rotary now applies `rope_type: "yarn"`. Our Qwen3.5 rows use
  `default`, so they are unaffected.

### New capabilities / API
- **Mid-turn steering (#608):** `ChatSession` queues instructions and applies them at text or step boundaries.
  This adds `Generation.steering(SteeringEvent)` and `GenerateStopReason.steered`. Both are emitted only by
  `ChatSession` steering. The app has no exhaustive switch over either enum.
- **Load progress (#551, 0877a36):** `LoadProgressHandlers` (`.download`, `.weights`). Weight reading now reports
  byte progress. The `progressHandler:` overloads are deprecated.
- **Checkpoint sampling defaults:** `GenerationConfigFile` decodes `temperature/top_p/top_k/min_p/repetition_penalty`.
  `ModelContainer.defaultGenerateParameters` exposes them. The app always passes its own `GenerateParameters`, so
  nothing changes for us.
- `ModelTypeRegistry.contains(_:configuration:)` (#778). Guided generation shows the response schema
  (#715, MLXFoundationModels only).

### Correctness fixes
- GLM-OCR prompts put images before text (#765), matching the model's template. This affects our `GLM-OCR-4bit-mlx` row.
- PythonLiteralParser decodes surrogate pairs, `\x`, octal and the other Python escapes (#769), and reads
  triple-quoted strings (#786). Pythonic tool calls with these values used to pass raw text to the tool.
- A flaky usage test on the tool-calling path is fixed (#784).

### Build / toolchain
- Integration tests run on Xcode 27 (#743). No toolchain floor moved.

### Tests
- There are large new suites: LFM2/LFM3/LFM2DSpark/LFM2MoE, Steering, MTP, ModelLoadProgress, UnreadCheckpointTowers,
  RotatingKVCacheKeepMask and Qwen35VLMYarn. The fork's `MiniCPM5FunctionParserTests` now target the upstream parser.

---

## Fork-local work this cycle

### Conflicts and fork patches (P3)
| File | Resolution |
|---|---|
| `MLXLLM/Models/LFM2.swift` | Took upstream verbatim. #528 absorbs both fork patches: the `intermediate_size` fallback and the `language_model.` prefix strip. Verified on the real `LFM2.5-2.6B-4bit` checkpoint, which has 600 `language_model.model.*` keys. |
| `Tool/ToolCallFormat.swift` | Took upstream's `.miniCPM5` / `MiniCPM5ToolCallParser` (#637). Kept the fork's `Gemma4FunctionParser` and the `fallbackParser` param. |
| `Tool/ToolCallFormatInference.swift` | Took upstream verbatim. The auto-merge had put in both MiniCPM5 signatures, and the fork one was dropped. |
| `Parsers/MiniCPM5FunctionParser.swift` | Deleted, replaced by upstream's parser. Its tests were retargeted and keep the recorded MiniCPM5-1B output. |
| `Parsers/MiniCPM5ToolCallParser.swift` | **New fork patch.** It overrides `parseEOS`, which put the start tag back on each segment so that a call still buffered at EOS is not lost. |
| `MLXLMCommon/Evaluate.swift` | **New fork patch.** #581 changed `RecordingGeneratedTokens` to return `SendableBox<RecordedGenerationResult>`. The fork-local `RecordingGeneratedTokenIDs` keeps `generateRecordingTokens(...) -> (AsyncStream<Generation>, Task<[Int], Never>)` unchanged for `AIChatModelMLX`. |

`wangqi modified` inventory: 27 files / 89 marks at `0a5ff28` → 25 files / 85 marks now. Upstream absorbed 7
marks (LFM2 −2, MiniCPM5FunctionParser −1, ToolCallFormat −2, ToolCallFormatInference −2), and 3 were added
(the new parser patch +1, Evaluate +2). Upstream deleted or renamed no fork-patched file. The fork's
`chunkedVLMPrefill` has had no caller since 2026-08-10 and is unchanged.

**Decision taken: MiniCPM5 truncated tool calls are discarded.** The fork parser kept a value cut off by the
token limit (no `</param>`/`</function>`). Upstream returns nil for that call. We took upstream, so no call
runs on truncated arguments (R3).

### Dependency reconciliation (P4)
No move: mlx-swift stays on `prism-1bit-0.33.0` and mlx core on `prism-1bit-0.32.4`. The PrismML patch is unaffected.
`swift build` is green, and the app package resolve shows no GitHub mlx-swift (P5).

### App consumers (P7)
- **`MiniCPM5ToolCallParser` name clash:** checked, no fix needed. The app's `class MiniCPM5ToolCallParser`
  (`ai/tool/parser/`) now shares its name with upstream's public struct. The app-module files that use it
  (`ToolCallParserChain.swift`) do not import MLXLMCommon, and an app-module declaration shadows an imported
  one anyway. The test files that use it (`ToolCallParserTests`, `CoreAIToolCallFallbackTests`) do not import
  MLXLMCommon either. No other new public type (38 checked) collides with an app type.
- **Deprecated `progressHandler:` loaders:** none in use. Every app and test load is `loadContainer(from: URL, using:)`.
  `loadMLXContainer(modelDirectory:progressHandler:)` takes a closure but never passes it to the library
  (see Opportunities).
- **Defaults that changed under us:** VLM dtype (#766), no effect on our bf16 rows. RotatingKVCache (#747) has no
  effect, since there is no capacity. Sampling defaults have no effect, since the app's parameters are explicit.
  The LFM2 cache topology did change (R2).
- **`PromptCacheReusePolicy`** gained speculative states (`trimToCommonPrefixMainOnly`,
  `SpeculativeCacheReuseCapability`). The app's main-only mirror (`MLXPromptCacheReuse`) needs no change.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Load memory | Lower footprint and peak on Gemma 4 and Qwen 3.5 rows (#711). The app's file-size load estimate now over-counts these rows, which is the safe side. |
| VLM KV memory | float16 VLM image prompts no longer double the KV cache (#766). |
| Nemotron-3-Nano-4B | Activations no longer in float32 (#754). Lower memory, faster decode, slightly different numerics. |
| LFM2.5 rows (5) | New model code (#528). Conv layers use `RewindableConvolutionCache`, so a prompt-cache rewind of up to 64 tokens can now be reused instead of rebuilt (R2). |
| GLM-OCR | Images before text (#765). OCR output may change. |
| MiniCPM5 tool calls | Upstream parser. Truncated calls dropped (R3). |
| Background / ANE | Nothing. MLX still needs the GPU. |

---

## Risk Assessment — **6 identified risks** (2 medium, 4 low)

### R1 — LFM2 rewrite on our five LFM2.5 rows (MEDIUM)
#528 replaces `LFM2.swift`/`LFM2MoE.swift` and adds `LFM2Support`, with new sanitize, mixed-precision quant and a new cache.
The rows affected are `LFM2.5-1.2B-Instruct-MLX-4bit`, `LFM2.5-2.6B-4bit`, `LFM2.5-8B-A1B-MLX-4bit` (MoE) and
`LFM2.5-VL-1.6B`/`-3B`. P3 verified the 2.6B key layout only.
*Verify:* run `MLXCatalogueRegressionTests` (Mac) on all five LFM2.5 rows and compare with the 20261030 baseline,
checking load, a coherent reply, a tool call and an image description for the VL rows.

### R2 — LFM2 convolution cache is now trimmable (MEDIUM)
`RewindableConvolutionCache.isTrimmable` is `true`. It used to be `MambaCache`, which is not trimmable. `applyPromptCacheReuse` in
`AIChatModelMLX` (`layers.allSatisfy { $0.isTrimmable }`) therefore now picks `trimToCommonPrefix` on LFM2.5 rows
where it used to rebuild. A conv layer can rewind at most 64 positions (`maxTrimCount`). A larger trim returns
0 for that layer, the existing `trimShortfall` check downgrades to a rebuild, and the attention layers are
discarded with the old cache. That is correct, but it costs one useless trim. A short rewind is now reused:
this is a speed win, and also a new correctness surface for hybrid rewind.
*Verify:* run `MLXPromptCacheReuseTests` and `MLXAssistantReplayTests`. Then run a live multi-turn chat on
`LFM2.5-1.2B-Instruct-MLX-4bit` (Mac, Protocol Inspector on). Check the `[MLX-KVREUSE]` lines for
`trimToCommonPrefix` versus `trimShortfall`. A reply after a rewind must match a cold-cache reply to the same
prompt at temperature 0.

### R3 — MiniCPM5 truncated tool calls are discarded (LOW, decision taken)
When a tool call is cut off by `maxTokens`, it is no longer executed with partial arguments. The user sees no
call. Rows: `MiniCPM5-1B-4bit` (MLX); the Core AI and GGUF rows use the app's own parser.
*Verify:* run `swift test --filter MiniCPM5` (fork; the "Content split on the start tag" case covers EOS
buffering) and `MLXCatalogueRegressionTests` on `MiniCPM5-1B-4bit` with its tool prompt. Restore the leniency
only if the regression shows truncated calls that matter.

### R4 — #711 component skipping on Gemma 4 / Qwen 3.5 (LOW)
The loader now decides per component whether to read the tensors. A wrong layout would fail the load or leave
weights unread. #711 says preparation still drops the same names, so the model is the same.
*Verify:* run `MLXCatalogueRegressionTests` on `gemma-4-e2b-it-4bit` (text and image) and `Qwen3.5-0.8B/2B/4B`. Run
`MLXMemoryBudgetTests` and `MLXKVCacheEstimateTests`; they should still pass, because the estimate only gets more
conservative.

### R5 — Numeric drift: Nemotron-H (#754), GLM-OCR prompt order (#765) (LOW)
Both changes are intended, but the outputs differ from the 20261030 baseline.
*Verify:* in `MLXCatalogueRegressionTests`, judge `NVIDIA-Nemotron-3-Nano-4B-4bit` and `GLM-OCR-4bit-mlx` by reply
quality, not by an exact match with the old output.

### R6 — `generateRecordingTokens` fork re-plumb (LOW)
The fork keeps the `[Int]` token-id API on a fork-local collector, because #581 changed the upstream type.
The prompt-cache ledger depends on these ids.
*Verify:* run `MLXPromptCacheReuseTests`, `MLXAssistantReplayTests` and `MLXFinalStatsTests`. Then run a live two-turn chat
on any text row and check the `[MLX-KVREUSE] decision=appendSuffix` line on turn 2.

---

## New models (MLX 4-bit, ≤ 4B)

Already in the catalogue: `MiniCPM5-1B-4bit`, all five LFM2.5 rows, and `LFM3-1.7B-Q4_K_M` / `LFM3-VL-2B-Q4_K_M` (GGUF only).
LFM Open License v1.0 allows redistribution with attribution, and the existing LFM MLX rows already rely on it.

| Model (HF repo) | Size | License | Decision | Reason |
|---|---|---|---|---|
| `LiquidAI/LFM3-1.7B-MLX-4bit` (`lfm3`) | 0.99 GB | LFM 1.0 | **Add** | A new family supported this merge, and the GGUF twin is already a row. Tools via `.xmlFunction` (`<tool_call><function=…>`), always-on `<think>`. Copy the GGUF row's sampling (temp 0.1, top_k 50, rep 1.1); `toolcall_parser_id` stays empty, as on the LFM2.5 MLX rows. Run `MLXCatalogueRegressionTests` before shipping. |
| `mlx-community/MiniCPM5-2B-mlx-4Bit` (`llama`) | 1.43 GB | Apache-2.0 | **Add** | The GGUF and Core AI 2B rows exist, and the template uses the same `<function name=` tool format, so `toolcall_parser_id: "minicpm5"`. The `-chat-mlx-4bit` repo is the same base and size, with fewer downloads. |
| `LiquidAI/LFM2.5-1.2B-Thinking-MLX-4bit` (`lfm2`) | 0.66 GB | LFM 1.0 | Decision | A small reasoning model, but LFM3-1.7B (always thinking, newer) covers the same slot. Add only if a sub-1 GB thinking row is wanted. |
| `LiquidAI/LFM2.5-VL-450M-MLX-4bit` (`lfm2-vl`) | 0.38 GB | LFM 1.0 | Reject | The GGUF row `LFM2.5-VL-450M-Q8_0` already covers it, and VL-1.6B is the MLX vision entry. |
| `LiquidAI/LFM2.5-350M-MLX-4bit`, `-230M-MLX-4bit` | 0.23 / 0.15 GB | LFM 1.0 | Reject | Too weak for general chat. |
| `LiquidAI/LFM3-VL-2B-MLX-4bit` (`lfm3_vl`) | 1.61 GB | LFM 1.0 | Reject | `lfm3_vl` is not registered in MLXVLM (#750 is text only). Revisit when upstream adds the wrapper. |
| `LiquidAI/LFM3-Omni-2B` / `LFM3-Audio-2B` MLX 4-bit | 2.13 / 1.75 GB | LFM 1.0 | Reject | `lfm3_omni` / `lfm3_audio` are unsupported. |
| `mlx-community/embeddinggemma-2-4bit` | 1.13 GB | Apache-2.0 | Decision | This is not a chat row. It would serve semantic search (Opportunities), but it bundles the vision and audio encoders, so a text-only conversion would be far smaller. |

---

## Opportunities (not built)

| Upstream feature | Consumer that would use it | Value |
|---|---|---|
| `LoadProgressHandlers.weights` (#551) | `AIChatModelMLX.loadMLXContainer` (its `progressHandler` is dropped today, so `load_progress` never moves) | A real load progress bar for large MLX models on iOS: one argument, `progress: .weights(progressHandler)`. |
| MTP speculative decoding (#581, #724, #774) | `AIChatModelMLX` text path on Qwen 3.5 rows (the checkpoints carry the MTP head) | Faster decode without a second model. It needs `ChatSession` or `MTPSpeculativeTokenIterator` in place of `generateRecordingTokens`. |
| Mid-turn steering (#608) | Chat input while a local reply streams | The user can redirect an answer without stopping it. Requires a `ChatSession` adoption. |
| Token log probabilities (#774, speculative too) | Laya / confidence displays, `AIChatModelMLX` | Per-token confidence from local models. |
| `ModelContainer.defaultGenerateParameters` | Model detail defaults for imported MLX models | Seed sampling from the checkpoint's `generation_config.json` when the user has not set values. |
| EmbeddingGemma 2 + `MultimodalEmbedding` (#692, #729, #787) | `RelevanceScorerFactory` (memory / knowledge base) | An on-device multilingual and image embedding with memory reporting. |
| LFM2.5 DSpark drafter (#528) | LFM2.5 rows | Speculative decoding for the LFM rows. |

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`). No app source changed in this upgrade.
2. Unit suites: `MLXFinalStatsTests`, `MLXKVCacheEstimateTests`, `MLXMemoryBudgetTests`, `MLXPromptCacheReuseTests`,
   `MLXAssistantReplayTests`, `MLXReasoningStreamTests`, `ToolCallParserTests`, `AppToolCallParserBridgeTests`,
   `CoreAIToolCallFallbackTests`, `MLXBrokenQuantConfigTests`.
3. Mac regression: `MLXCatalogueRegressionTests` on all MLX rows. R1, R4 and R5 must be judged by quality.
4. Add the rows for `LFM3-1.7B-MLX-4bit` and `MiniCPM5-2B-mlx-4Bit` (mirror, `models_test.json`), add LFM3 to
   `mlxSwiftSupportedModels`, and record #711 and the LFM2.5 cache in `helper/docs/mlx-swift.md`.
