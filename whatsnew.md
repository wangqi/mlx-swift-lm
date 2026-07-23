# mlx-swift-lm Upgrade — `tag-20260714` → `tag-20260722`

**Merged:** 2026-07-22
**Upstream base:** `ml-explore/mlx-swift-lm` main (37 commits; PRs #399, #455, #398, #442, #423, #389, #409, #435, #334, #232, #457, #405, #364, #383, #384, #415, #381, #437, #369, #429, #430, …)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

This upgrade brings 37 upstream commits. For our iOS integration the single most important item is **PR #399 (Qwen3.5/3.6 windowed prefill + state-threaded warm continuation)**: upstream added its own native chunked prefill for Qwen3.5, bounding attention scratch to `[heads, window, L]` instead of `[heads, L, L]` — the exact class of Metal out-of-memory abort our fork-local `chunkedVLMPrefill` patch was created to prevent. During the merge we adopted upstream's implementation wholesale for Qwen3.5 (it now also fixes a real multi-turn M-RoPE drift bug), while keeping the fork-local iOS chunked-prefill patch on the models upstream did **not** rework (Qwen2VL, Qwen3VL, Qwen2.5-VL, Gemma3). Alongside this, two directly iOS-facing crash fixes landed (background-GPU cancellation in the prefill loop, #423/#389) and Qwen3-VL vision attention was rewritten to slash peak memory on large / multi-image prompts (#455, #398).

---

## Highlights

### On-device / iOS memory & stability
- **Qwen3.5 windowed prefill + warm continuation (#399).** Native chunked prefill bounds attention scratch to `[heads, window, L]`; also threads M-RoPE `LMOutput.State` across turns, fixing measurable cross-turn logit drift (0.43 max-abs vs. a 8.3e-07 floor) on repeated image turns. **Supersedes our fork's iOS chunk patch for Qwen3.5** (adopted wholesale in the merge; see R1).
- **Qwen3-VL vision: per-image fused SDPA instead of a dense joint mask (#455).** Drops a `[1, L, L]` -1e9 mask and pads head-dim 72→80 to hit the fused kernel. Measured on M4 Pro: single 6120-token image peak 28.7 → 12.5 GB; a two-image 8140-token request went from fatal (exceeded `maxBufferLength`) to 14.2 GB. Directly relevant to iOS memory ceilings.
- **Qwen3-VL per-image 1,280 vision-token budget (#398).** Caps `min(maxPixels, 1280·factor²)` to avoid unbounded O(patches²) attention blow-up on full-resolution images.
- **iOS background-GPU crash fixes (#423, #389).** Cooperative cancellation is now checked between prefill windows and before each `iterator.next()`, so a long prefill can be cancelled on `willResignActive` before GPU work is enqueued — GPU work submitted while backgrounded is rejected by the OS and aborts the process. This aligns with our existing background-inference handling.
- **Qwen3.5 / Qwen3-VL interleaved M-RoPE optimization (#442).**
- **TurboQuant KV-cache compression (#232).** Optional `kvScheme` KV compression (Walsh-Hadamard rotation + Lloyd-Max codebooks, JIT Metal kernels) for lower long-context memory. Opt-in; unused paths unchanged.

### New models / capabilities
- **MLXFoundationModels + MLXGuidedGeneration (#334).** An MLX-backed `FoundationModels.LanguageModel`, plus a standalone guided-generation library that constrains output to a JSON Schema / EBNF / structural tag via a vendored, namespace-isolated XGrammar (`MLXCXGrammar`). Gated by the default-on `FoundationModelsIntegration` trait; compiles to an empty module on older SDKs; minimum OS versions unchanged (iOS 17 / macOS 14 for guided generation, iOS 27 for the FoundationModels adapter).
- **Gemma 4 26B-A4B MoE via MLXLLM text path (#364)** and **E-series (E2B/E4B) MTP speculative decoding (#383, #384, #415)** — centroid embedder for `use_ordered_embeddings`, KV-shared-layer loader fix, and 12B `gemma4_unified` drafter support.
- **DeepSeek V3 now actually generates (#457, #422).** Two cached-path bugs (empty `kvHeads` → index-out-of-range; double KV-cache update) fixed; init made public.

### New capabilities / API (that we may adopt)
- `LanguageModel.prepare` now threads an optional `LMOutput.State` (M-RoPE state); `ChatSession`/`TokenIterator` persist it across turns and tool restarts (#399). Non-Qwen3.5 conformers accept and ignore it.
- `BaseKVCache.ropeOffset` is now an `open` overridable witness (#437).
- `getRopeIndex` gains offset-aware `positionOffset` (#399).

### Correctness fixes
- **Tool round-trip: assistant `tool_calls` message recorded before tool results (#409).** Chat templates that forward-scan from an assistant tool-call message (e.g. Gemma 4) previously dropped tool results. We adapted upstream's typed `[ToolCall]` append to the fork's dict-based `Chat.Message` (see R2).
- **VLM tool-calling input rank (#435).** Tool-aware prompts now route through `context.processor.prepare`, producing the `[1, N]` rank VLMs require (previously a 1-D array aborted with `SmallVector out of range`) and preserving image/video content.
- Mixed-precision quantized checkpoint loading pinned (#395, Gemma 4 QAT 8-bit MLP / 4-bit rest).
- Gemma 4 aspect-preserving resize + multi-image requests (#405); EOS IDs from nested text configs (#449); optional pooling-config flags (#376); GDN non-multiple-of-32 key-dim truncation guard (#381); tool-schema `$defs` hoisting for grammar compilation (#434).
- FoundationModels SDK drift fixes (#439 usage-emit SIGSEGV on FM-27, #438, #431 sampling-mode case rename).

### Build / toolchain
- **mlx-swift 0.31.5 adds the `CudaBuild` build-tool plugin (#430).** Upstream's normal SwiftPM resolution now pulls mlx-swift 0.31.5, whose `encuda`/`CudaBuild` build-tool plugin uses `Foundation.Process` (iOS-hostile) and requires `-skipPackagePluginValidation` for non-interactive `xcodebuild`. **We do not take the full 0.31.5 bump** — instead we cherry-picked only the additive API commit (#429, `DType.greatestFiniteMagnitudeArray` + `MLXArray.maskFill`) onto our PrismML `mlx-swift` 0.31.4 fork, so the CudaBuild plugin never enters our graph (see R3).
- `finfo.min` port for quantized attention masking corrected (#369).
- MLXLLM made Linux-compilable (#321).

### Tests
- New regression suites: `DeepseekV3Tests`, `MixedPrecisionQuantLoadTests`, `Qwen35ContinuationTests`, `Qwen3VLProcessorConfigTests`, `Gemma4ResizeTests`, `Gemma3EncoderAccessTests`, `TurboQuantTests`, `ChatSessionToolRoundTripTests`, plus MLXFoundationModels/MLXGuidedGeneration test targets.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Qwen3.5-VL prefill | Native windowed prefill replaces fork patch; lower peak memory + fixed multi-turn drift (#399) |
| Qwen3-VL vision attention | Peak memory roughly halved on large/multi-image prompts; multi-image no longer fatal (#455, #398) |
| Background cancellation | Long prefill now cancellable before GPU submit → fewer background Metal aborts (#423, #389) |
| Tool-calling | VLM tool turns no longer crash; tool history renders correctly for Gemma-style templates (#435, #409) |
| KV cache memory | Optional TurboQuant compression available for long contexts (#232) |
| Dependency (mlx-swift) | Needs 0.31.5-only APIs; satisfied by a cherry-pick onto our 0.31.4 PrismML fork, avoiding the CudaBuild plugin (#429/#430) |
| PrismML quantization | Unaffected — cherry-pick touches no quant shaders, core, or `QuantizationTests` |

---

## Risk Assessment — **5 identified risks (1 medium, 4 low)**

### R1 — Qwen3.5-VL prefill path replaced by upstream's windowed prefill (MEDIUM)
The recurring chunked-prefill overlap. Upstream #399 reworked Qwen3.5 prefill; the merge collided with our fork-local iOS `chunkedVLMPrefill` patch, and we resolved it by **adopting upstream wholesale** (`Qwen35.swift` is now byte-identical to upstream). Upstream's `prepareContinuation` gates on `inputIds.ndim == 2` — our VLM processor always emits `[1, seq]` (confirmed in `AIChatModelMLX.swift:265`), so long prompts (>512 window, incl. the ~6.5K-token crash case) route to the chunked path. Static analysis holds, but the on-device runtime path changed.
*Verify:* `testcases/MLXVLMLongPromptTests.swift` `testVLM_Qwen35_LongPrompt_NoAbort` with a real Qwen3.5-VL checkpoint (env-gated), plus an on-device long-prompt + multi-turn-with-image smoke test. Regression math: `MLXVLMLongPromptTests` chunk-slicing tests.

### R2 — ChatSession assistant `tool_calls` append adapted to fork dict shape (LOW)
Upstream #409 added `messages.append(.assistant("", toolCalls: pendingToolCalls))` with a typed `[ToolCall]`; the fork's `Chat.Message.toolCalls` is `[[String: any Sendable]]`. We convert to the OpenAI-nested dict shape (`{id, type, function:{name, arguments-as-JSON-string}}`) matching `AIChatModelMLX`. This `toolDispatch` path is **not used by the app** (the app builds its own tool history), and the shape matches exactly what upstream's `ChatSessionToolRoundTripTests` asserts.
*Verify:* `ChatSessionToolRoundTripTests.testRestartedGenerationSeesAssistantToolCallsBeforeResults` (compiles against the fork; run under Xcode/Metal).

### R3 — mlx-swift version dependency satisfied by cherry-pick, not a full 0.31.5 bump (LOW)
Upstream's merged code uses `DType.greatestFiniteMagnitudeArray` (Gemma residual clip) and `MLXArray.maskFill` (KVCache attention masking), added in mlx-swift 0.31.5 (#429). A full 0.31.5 bump would drag in the iOS-breaking `encuda`/`CudaBuild` build-tool plugin (#430). We instead cherry-picked the single additive commit #429 onto our PrismML `mlx-swift` fork (`prism-1bit-0.31.4`, commit `37b3ca1`). The commit touches only `DType.swift` + a new 14-line `MLXArray+maskFill.swift` — no quant shaders, no vendored core (`ce45c52` unchanged), no `QuantizationTests`.
*Verify:* `thirdparty/mlx-swift/Tests/MLXTests/QuantizationTests.swift` `testBitExactRegression` + `testLowBitReconstruction` (run under Xcode/Metal). The fork commit is currently **unpushed** — push to `wangqi/mlx-swift` for reproducibility.

### R4 — DeepSeek V3 / Gemma 4 loader behavior changes (LOW)
DeepSeek V3 cached-path fixes (#457) and Gemma 4 KV-shared-layer loader (#384) change generation on those families. Both ship regression tests; neither is a default on-device model here. Low blast radius.

### R5 — FoundationModels SDK drift (LOW)
Several FM fixes (#439 usage-emit SIGSEGV on FM-27, #438, #431 sampling-mode renames). Gated behind the `FoundationModelsIntegration` trait and iOS/macOS 27. The adapter is compiled in our build but not yet wired into app flows; guided generation (XGrammar) is available from iOS 17. Low risk to shipping paths.

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`). — **DONE** (both BUILD SUCCEEDED).
2. Run `testcases/MLXVLMLongPromptTests.swift` `testVLM_Qwen35_LongPrompt_NoAbort` on device for R1, plus a manual Qwen3.5-VL long-prompt / multi-turn-with-image smoke test.
3. Run `QuantizationTests` under Xcode for R3; push the `mlx-swift` fork cherry-pick (`37b3ca1`) to `wangqi/mlx-swift`.
4. `helper/docs/mlx-swift.md` "Models currently patched" list is unchanged in shape — Qwen3.5 is now upstream-chunked rather than fork-chunked; note that Qwen3.5 no longer relies on the fork `chunkedVLMPrefill` helper (the helper still serves Qwen2VL/Qwen3VL/Qwen2.5-VL/Gemma3).
