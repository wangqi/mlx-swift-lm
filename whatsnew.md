# mlx-swift-lm Upgrade — `tag-20260918` → `tag-20260928`

**Merged:** 2026-09-28
**Upstream base:** `ml-explore/mlx-swift-lm` main @ `ee673d6` (1 upstream PR: #603)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

The smallest upgrade the fork has taken. It contains one upstream PR, **#603**, and every line of it
is in `Libraries/MLXFoundationModels` or that library's tests. `MLXFoundationModels` is the adapter that exposes an MLX model through Apple's
FoundationModels `LanguageModel` API. **This app does not link that product.** `AIAssistant.xcodeproj`
depends on `MLXLLM`, `MLXVLM` and `MLXLMCommon` only, and SwiftPM builds only the products a target
depends on, so none of #603's code reaches either app binary. `MLXLMCommon`, `MLXLLM`, `MLXVLM` and
`Package.swift` are byte-identical between `tag-20260918` and `tag-20260928`. The merge had no
conflicts.

As shipped, the upgrade changes nothing about how a model loads, prefills, decodes or calls a tool.
This cycle's regression run caught one real, **pre-existing** failure: `LFM2.5-2.6B-4bit` has not
loaded since it entered the catalogue. It is fixed in the fork here (see "Fork-local fix" below): two separate
defects in `LFM2.swift`, the second hidden behind the first.

---

## Highlights

### On-device / iOS memory & stability
- Nothing on our path. `MLXLMCommon` (generation loop, KV cache, prefill, tool-call layer) is unchanged.

### New models
- None.

### New capabilities / API (all in `MLXFoundationModels`, none adopted)
- **`ModelCache` is its own file and a non-private actor (#603).** It moved out of
  `MLXLanguageModel.swift` without any content change. It is still internal to the module.
- **`evictAll()` now cancels every registered load (#603).** Before, it dropped the registrations
  without cancelling them, so a load still running when the whole cache was evicted became unreachable
  and still allocated. A caller awaiting `preload()` / `respond()` now fails instead. Cancellation is
  cooperative, so a load already inside `loadWeights` still finishes. `evict()` had the same limit.
- **Download progress is tracked per model (#603).** `MLXDownloadProgress` keeps one entry per model
  ID and one identifier per load. Every report goes through one stream to one main-actor consumer,
  and the end of a load is reported from a `defer`. This fixes three bugs: concurrent downloads
  overwrote each other's progress, a cancelled load stayed "active" for the life of the process, and
  a late progress report could reappear after a download finished. `isActive` / `modelName` are
  replaced by `activeDownloads` / `download(forModelID:)`, and the throughput property is now
  `throughputBytesPerSecond`. None of these names were ever in a release.
- **Constraint-clone failures narrowed (#603).** `try?` became a catch on `GrammarError.forkFailed`,
  matching the cached-template clone site. No behaviour change today.
- **Renames (#603).** `xgTokenizers` → `grammarTokenizers`, `makeXGTokenizer` → `makeGrammarTokenizer`,
  `hasCachedXGTokenizer` → `hasCachedGrammarTokenizer`.

### Correctness fixes
- The `evictAll()` and per-model progress fixes above, which only matter to a FoundationModels consumer.

### Build / toolchain
- No change. The `FoundationModelsIntegration` trait is still default-on. The adapter is compiled only
  when a target depends on the `MLXFoundationModels` product, which ours do not.

### Tests
- New `MLXDownloadProgressTests` (405 lines) and `ModelCacheEvictionTests`. Both eviction tests have a
  time limit, because a regression would leave a parked loader waiting forever. Nine `GuidedGeneration`
  suites were updated for the tokenizer renames.

---

## Fork-local fix taken this cycle (not from upstream)

### `LFM2.5-2.6B-4bit` loads for the first time
The MLX regression suite's first Swift-engine run (2026-09-18) failed this model with
`UpdateError: Key model.embed_tokens.weight not found in LFM2Model.LFM2ModelInner.Embedding`. The
key it names changes from run to run with dictionary order (`embedding_norm.weight` in the tool-call
run). The published `mlx-community/LFM2.5-2.6B-4bit` checkpoint prefixes all 600 tensors with
`language_model.`: it was converted through a VLM-shaped path and carries an empty `vision_config`.
Its `config.json` still declares `Lfm2ForCausalLM` / `model_type: lfm2`, and it has no
`preprocessor_config.json`, so `loadMLXContainer` sends it to `LLMModelFactory` → `LFM2Model`.
`LFM2Model.sanitize` only transposed conv weights and left the prefix. `UpdateError` is not
`unsupportedModelType`, so the VLM fallback never ran. The model ships in `helper/models.json`
(prod), so **no user could load it.**

*Fix, in two parts, both in `Libraries/MLXLLM/Models/LFM2.swift`:*
1. `LFM2Model.sanitize` now strips a leading `language_model.` (anchored, so a key that merely
   contains the text is untouched), the same normalization Qwen35 / Gemma4 already apply.
2. That exposed the next failure: `UpdateError: Mismatched parameter
   model.layers.0.feed_forward.w1.weight`. This `config.json` has the current Transformers key
   `intermediate_size` (10752) and no legacy `block_ff_dim`, so `blockFFDim` fell back to
   `hiddenSize` (2048). `LFM2Configuration` now reads `intermediate_size` when `block_ff_dim` is
   absent, as Transformers' `Lfm2Config` does. It only changes configs that lack `block_ff_dim`,
   and those configs could never have loaded, because the `hiddenSize` fallback does not match any
   shipped LFM2 FFN. `LFM2.5-1.2B-Instruct` and `LFM2.5-VL-3B` carry both keys with equal values.
`LFM2MoE` was not changed: its catalogue rows (`LFM2.5-8B-A1B`) load today, and adding a
speculative rewrite there would change a path that works.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Generation, prefill, KV cache, tool calls | **None.** `MLXLMCommon` / `MLXLLM` / `MLXVLM` byte-identical across the range |
| `MLXFoundationModels` (#603) | Not linked by the app, so no effect |
| `LFM2.5-2.6B-4bit` | Now loads (fork-local sanitize + FFN-size fix). Previously failed on every device |
| Dependency / PrismML | **No move.** `Package.swift` byte-identical; `mlx-swift` stays `0.31.4` (`dc43e62` + `37b3ca1`), core `0.31.1` (`ce45c52`) |

---

## Risk Assessment — **2 identified risks** (0 medium, 2 low)

### R1 — Adopting `MLXFoundationModels` later means adopting the new progress API (LOW)
If the app ever serves an MLX model through FoundationModels' `LanguageModel` (so that `AIChatModelApple`
could run a local MLX model), code written against the old single-download `MLXDownloadProgress`
(`isActive`, `modelName`) will not compile. Nothing uses it today.
*Verify:* nothing now. Revisit only if a target adds the `MLXFoundationModels` product.

### R2 — The LFM2 prefix strip and FFN-size alias touch every LFM2 load (LOW)
`sanitize` runs for every `lfm2` checkpoint, including `LFM2.5-1.2B-Instruct-MLX-4bit`, whose keys are
unprefixed. The strip is anchored on `language_model.`, and `LFM2Model` has no module with that key,
so no well-formed checkpoint can match it. The LFM2VL path is unaffected: it uses `LFM2VL.sanitize`
with its own `language_model` module. The `intermediate_size` alias applies only when
`block_ff_dim` is missing, so a config that loaded before resolves to the same FFN size.
*Verify:* the MLX regression suite covers both shapes: `LFM2.5-1.2B-Instruct-MLX-4bit` (unprefixed),
`LFM2.5-2.6B-4bit` (prefixed), plus `LFM2.5-VL-1.6B` / `LFM2.5-VL-3B` (VLM path).

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`). The MLX regression suite's macOS
   `build-for-testing` covers the macOS side.
2. No VLM prefill surface changed, so `testcases/engines/local/MLXVLMLongPromptTests.swift` needs no
   device run this cycle.
3. The previous cycle's open item still stands: confirm #620's first-token `clearCache()` direction on
   an iPhone `cacheLimit` tier (64-256 MB) with one Protocol Inspector session.
