# mlx-swift-lm Upgrade — `tag-20261017` → `tag-20261024`

**Merged:** 2026-10-24
**Upstream base:** `ml-explore/mlx-swift-lm` main (8 upstream PRs: #683, #702, #706, #710, #714, #718, #719, #721)
**Old fork tip:** `3daf7bbbc` · **New:** `2aa485b` (merge of upstream/main)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

A small weekly merge: 8 upstream commits. No conflicts needed manual work, no fork patch moved, and no
dependency changed. For our iOS integration the one item that matters is **#710**:
`PrefillParameters.forEachChunk` now calls `Memory.clearCache()` after every prefill chunk. That
lowers peak memory on long prompts for every MLX LLM and VLM the app ships. It also means decode now
starts with an empty buffer pool after a long prefill, which the app had deliberately avoided
(see R1). Everything else is either outside the products the app links (`MLXFoundationModels`,
`MLXGuidedGeneration`, `MLXScriptedLM`, LoRA training) or covers a model the catalogue does not
ship (Qwen3-VL, #706). Nothing here blocks shipping.

---

## Highlights

### On-device / iOS memory & stability
- **The MLX buffer cache is cleared after each prefill chunk (#710)**, as Python mlx-lm does. The KV
  cache grows with every chunk, so the buffers it outgrows can never be reused, and before this change
  they stayed in the pool until `cacheLimit` evicted them. This applies to every model whose `prepare`
  goes through `forEachChunk`: all MLX LLMs, plus LFM2-VL, Qwen3.5 and GLM-OCR among the VLMs.
  Prompts that fit in one step (shorter than `n_batch`, 512 by default) take no chunk loop and are
  unaffected.

### New models
- None. No new architectures in this range.

### New capabilities / API
- **Request-scoped generation observations in `ChatSession` (#714):** `ChatSession.observe(_:transformer:)`
  with a `GenerationTransformer` (`.text`, `.logProbabilities(topCount:)`), a new
  `GenerationTransformer.swift`, and `LogProbabilityGeneration.logProbabilities`.
  `TextToolTokenLoopHandler` now carries `cachedPromptTokenCount` and attributes it to the completion
  info. Only `ChatSession` sets it. The app drives `generateRecordingTokens` directly and does not use
  `ChatSession`.
- **`MLXLogger` replaces `os.Logger` in the library (#702):** `GuidedGenerationLoop`, `InferenceState`,
  `TextToolTokenLoopHandler` and ParoQuant now use mlx-swift's `MLXLogger(label:)`. The Linux `Logger`
  shims are deleted. `MLXLogger.factory` is a process-wide hook for routing these logs (see Follow-ups).
- **`MLXScriptedLM` gains `ScriptedLogitsModel`, `ForwardingLanguageModel`, transcripts and turn
  scripts (#719)**, a test-only library that now depends on `MLXNN`.

### Correctness fixes
- **Qwen3-VL attention masks after a cache rotation (#706).** The model builds one shared mask from the
  retained cache window (`createAttentionMask(h:cache: cache?.first)`) and passes the mask mode to
  every layer. Before, each layer sliced a full mask by an absolute length, which broke once a rotating
  cache had wrapped. Absolute M-RoPE positions are preserved. Only `qwen3_vl` is affected:
  Qwen3.5/3.8 (`Qwen35.swift`) and Qwen3-VL-MoE are untouched.
- **Guided-generation JSON follows the schema's declared property order (#718)**
  (`MLXFoundationModels/GuidedGeneration/SchemaConverter.swift`). The app does not link it.
- **LoRA training on prompts shorter than the batch (#683).** The app does not link it.

### Build / toolchain
- No dependency move. `Package.swift` still uses `.package(path: "../mlx-swift")` (mlx-swift 0.32.3, so
  the 0.32.3 floor holds). `MLXLogger` was already present in that tag. `Package.resolved` is unchanged.
  `MLXFoundationModels` / `MLXGuidedGeneration` exclude their README files.

### Tests
- New: `PrefillClearCacheTests`, `Qwen3VLContinuationTests` (+ `Qwen3VLCacheIntegrationTests`),
  `ChatSessionObservationPerformanceTests`, `SchemaPropertyOrderTests`, `LoRATrainDataTests`,
  ScriptedLM suites. `MatmulPrecision.swift` adapts several model tests to the new TF32 comparison
  issues (#721). `Gemma3TextConfiguration.smallConfiguration` / `tinyConfiguration` (`@_spi(Testing)`)
  were added for tests.

---

## Fork-local work this cycle

### Conflicts and fork patches (P3)
- Files changed on both sides since base `48114ee`: `ChatSession.swift`, `Evaluate.swift`,
  `TokenLoopHandler.swift`, `Package.swift`, `Tests/MLXLMTests/ChatSessionTests.swift`. Every line the
  fork added is still present (0 missing), and no line the fork removed came back.
- Upstream's changes to the hot files are additive. `TokenLoopHandler`: the `MLXLogger` swap and
  `cachedPromptTokenCount`. `Evaluate`: a new internal `generateTaskRecordingTokens<Handler>` overload.
- **Tool-call patches intact:** `fallbackParser` is still threaded `TextToolTokenLoopHandler.init` →
  `makeTokenStreamDecoder` → `ToolCallProcessor`. Both fork entry points still pass it:
  `Evaluate.swift:2203` (`generate…(fallbackToolCallParser:)`) and `:2372` (`generateTask`).
  `Libraries/MLXLMCommon/Tool/` is untouched. The `wangqi modified` marker lists are identical in OLD and NEW.
- ChatSession's handler (now built through `transformer.makeHandler(wrapping:)`) and three other upstream
  `generate` overloads do not pass `fallbackParser`. They did not in OLD either, and the app does not
  use them.
- LFM2 fork fixes (`intermediate_size`, `language_model.` prefix strip) are present and the merge did not touch them.
- #706 applies cleanly: the fork has no delta in `Qwen3VL.swift`.

### Chunked VLM prefill: decision
- `chunkedVLMPrefill` (`Libraries/MLXVLM/ChunkedPrefill.swift`) has **no production callers**. That
  was already true at OLD: LFM2-VL moved to upstream's `forEachChunk` in tag-20260810. The only caller is
  `testcases/engines/local/MLXVLMLongPromptTests.swift`. The helper already delegates to `forEachChunk`,
  so it inherits #710's per-chunk cache clear with no double chunking.
- **Coordinator decision: keep the file** as a tested helper. It is ready if Qwen3-VL-MoE or Paligemma
  (both still single-shot `prepare` upstream) ever ship on iOS. The "VLM chunked prefill (iOS)" rule in
  `helper/docs/mlx-swift.md` (§ at line ~1214, "every VLM MUST route through it") has been stale since
  tag-20260810 and is corrected in P12.

### Dependency reconciliation (P4)
- No move. The mlx-swift 0.32.3 floor is satisfied. The PrismML 1-bit/2-bit patch
  (`thirdparty/mlx` `prism-1bit-0.32.2`, `thirdparty/mlx-swift` `prism-1bit-0.32.3`) is unaffected, so
  no shader regeneration. P5: the app's packages resolve, with no GitHub `ml-explore/mlx-swift` in `Package.resolved`.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Long-prompt prefill | Lower peak memory: outgrown buffers are released after each chunk (#710) |
| Decode after a long prefill | Starts with an empty buffer pool. First-token allocation misses, see R1 (#710) |
| Short prompts (< `n_batch`) | Unchanged: no chunk loop |
| Qwen3-VL (not in catalogue) | Correct attention after a KV rotation (#706) |
| Tool calls | Unchanged: fork parser path intact |
| Logging | Library logs go through `MLXLogger` (OSLog by default on Apple platforms) (#702) |
| Dependencies / PrismML | Unchanged |

---

## Risk Assessment — **3 identified risks** (1 medium, 2 low)

### R1 — #710 cache clear versus the app's warm-pool tuning (MEDIUM)
`AIChatModelMLX.buildGenerateParameters` (`ai/AIChatModelMLX.swift:2021-2026`) records why the app
*removed* its per-generation `clearCache()`: emptying the warm pool before every generation forced
per-token allocation misses (about twice as slow decode). #710 clears the pool after every chunk,
including the last one, so a long-prompt turn now enters decode with an empty pool. A short turn does
not. mlx-lm has done this for a long time and the pool refills within the first decode steps, so the
expected effect is lower prefill peak with at most a transient decode cost. On iOS that is a good trade
under `cacheLimit` tiers of 64–1024 MB. Smaller steps mean more clears: thermal throttling halves or
quarters `n_batch` (`thermallyAdjustedPrefillStep`, `:1985`). The P1/P10 regression prompts are
shorter than one step, so **the regression gate does not exercise #710 at all**.
*Verify:* run a prompt of 2K+ tokens on an MLX LLM (e.g. `Qwen3.5-2B-MLX-4bit`) and a VLM
(`LFM2.5-VL-1.6B-MLX-4bit`) on device, on OLD and NEW. Compare the `[MLX-PERF] done … prefillTps=…
decodeTps=… peak=…` lines in the MLX log. Expect a lower `peak` and a `decodeTps` within noise. On
macOS, `testcases/engines/local/MLXVLMLongPromptTests` exercises the chunked path.
*Status:* needs device.

### R2 — #706 changes Qwen3-VL outputs (LOW)
The mask now comes from the retained window, so long Qwen3-VL conversations past a rotation change
(they get more correct). No catalogue row is `qwen3_vl`, and Qwen3.5 / Qwen3.8 use `Qwen35.swift`, which
did not change. *Verify:* only if a Qwen3-VL row is added: `--mlx-only --only <id>` plus a multi-turn
image conversation with `maxKVSize` set.

### R3 — MLXLogger replaces os.Logger (LOW)
The labels changed from `subsystem: "mlx-swift-lm", category: …` to `MLXLogger(label:)`. Anything that
filtered Console/OSLog by the old subsystem would miss these lines. The app does not read
OSLog for MLX (it logs through `AppLogger` / `MLXLogCollector`). *Verify:* `swift build` green (P3);
no app code references `Logger(subsystem: "mlx-swift-lm"…)`.

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`). The iOS build is the only one that compiles the
   `#if os(iOS)` fork paths.
2. R1 device check: a long-prompt LLM and VLM turn, comparing `[MLX-PERF]` lines with OLD.
3. Optional: set `MLXLogger.factory` once at startup to route the library's warnings (tool-call
   rejections in `TextToolTokenLoopHandler`, `InferenceState` preparation failures) into `AppLogger`.
4. `ai/AIChatModelMLX.swift:951-954`: a comment still says prefill runs "chunkedVLMPrefill → eval(cache)".
   It now runs `forEachChunk`. This is a cosmetic fix, to make with the P12 doc correction.
5. No new models, so no catalogue changes.
