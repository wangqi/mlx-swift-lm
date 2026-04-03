# mlx-swift-lm Upgrade Notes: tag-20260328 → tag-20260403

## Summary

Three upstream commits bringing Swift 6 strict concurrency, a major tokenizer/downloader
decoupling (10x–15x model load speedup), and a RoPE unification refactor across 45 model files.
Our custom crash-guard patches (`QuantizationBitsError`, `ModelLoadError`) were preserved through the merge.
Overall risk is **low–medium**: no API breakage for our local-directory loading pattern;
the main watch item is Swift 6 strict concurrency build compatibility.

---

## Changes

### 1. Swift 6 Strict Concurrency (#165)

- `Package.swift` upgraded to `swift-tools-version: 6.1`.
- Concurrency issues in `ChatSession.swift` fixed under strict actor isolation rules.
- `mlx-swift` bumped to **0.31.3**, fixing a `save_safetensors` concurrency issue.
- **iOS impact**: Low risk. Library-internal change. May surface strict-concurrency build
  warnings in consuming code — review `AIChatModelMLX.swift` if build errors appear after upgrade.

---

### 2. Decouple Tokenizer and Downloader from HuggingFace Hub (#118)

- **`swift-transformers` dependency removed** — replaced with `swift-tokenizers`, a streamlined
  fork focused purely on tokenizer functionality with no HuggingFace or Core ML code.
- **10x–15x speedup in model loading** on Apple Silicon. The new tokenizer loads in a few hundred
  milliseconds instead of several seconds.
- New `Downloader` protocol abstracts model hosting (local directory, HuggingFace Hub, ModelScope,
  custom buckets). HuggingFace-specific code moved to the new optional `MLXHuggingFace` module.
- **Breaking API changes (upstream-facing)**:
  - `hub: HubApi` parameter replaced with `from: Downloader` (or `URL` for local paths).
  - `downloadModel(hub:configuration:progressHandler:)` removed — replaced by `Downloader.download(...)` in `MLXHuggingFace`.
  - `defaultHubApi` global removed — use `HubClient.default` from `MLXHuggingFace`.
  - `tokenizerId` / `overrideTokenizer` on `ModelConfiguration` replaced with `tokenizerSource: TokenizerSource?`.
  - `loadTokenizerConfig(configuration:hub:)` removed — use `AutoTokenizer.from(directory:)`.
- **iOS impact for our app**: Low risk. We always load from local directory
  (`ModelConfiguration(directory: modelDirectory)`) and call `loadContainer(configuration:progressHandler:)`,
  which remains intact. We do not use `HubApi`, `downloadModel`, or `tokenizerId` directly.
  `import Tokenizers` removed from `MLXLMCommon/Load.swift` (our merge resolution preserved the
  custom `QuantizationBitsError` and `ModelLoadError` error types used in `loadWeights`).

---

### 3. Unify RoPE Application Across 45 Models (#178)

- New `RoPEApplication.swift` with `applyRotaryPosition(rope:to:cache:)` helper, centralizing
  the `cache?.offset ?? 0` pattern that was duplicated across all model attention layers.
- Migrated 45 model attention layers to the shared helper. Pure refactoring — no behavior change
  for single-request inference.
- Model-specific fixes:
  - **SmolLM3**: Replaced custom `SmolLM3PositionEmbedding` protocol with standard `RoPELayer`.
  - **Internlm2**: Added `OffsetLayer`/`ArrayOffsetLayer` conformance; extracted `computeBase` helper.
  - **NanoChat**: Wrapped `MLXFast.RoPE` in new `NanoChatRoPE` class conforming to `RoPELayer`.
  - **Phi3**: Removed `PositionalEncoding` enum; uses `RoPELayer` directly.
  - **GPTOSS**: Unified quantized and regular rope paths.
  - **Gemma3nText / Gemma3Text**: Fixed rope type to `OffsetLayer & ArrayOffsetLayer`.
- **iOS impact**: Low risk. No user-visible behavior changes. Lays groundwork for future batch-aware RoPE dispatch.

---

## iOS-Specific Impact

| Change | Impact |
|--------|--------|
| Swift 6 language mode | Build-time: may surface strict-concurrency warnings in consuming code |
| Tokenizer decoupling | 10x–15x faster model loading for all MLX models on device |
| `swift-transformers` removed | Simpler dependency tree, faster `swift package resolve` |
| RoPE unification (45 models) | No runtime impact; improves long-term maintainability |
| mlx-swift bumped to 0.31.3 | Fixes `save_safetensors` concurrency issue |

---

## Risk Assessment

**Overall Risk: LOW–MEDIUM**

| Area | Risk | Reason |
|------|------|--------|
| Swift 6 build | Medium | swift-tools-version 6.1 may require consuming code to handle strict concurrency |
| API compatibility | Low | We use `loadContainer(directory:)` — removed Hub APIs are not used by our app |
| Tokenizer speedup | Positive | 10x–15x faster model loading on device |
| RoPE refactor (45 models) | Low | Pure refactoring, no inference behavior change |
| Dependency tree | Positive | `swift-transformers` removed, simpler and faster resolution |

**Recommended:** Run a test build against the merged submodule to confirm no Swift 6
strict-concurrency errors in `AIChatModelMLX.swift` before shipping.

---

## Our Custom Patches (preserved across merge)

- `QuantizationBitsError` — prevents fatal crash on unsupported quantization bit depths (e.g. 7-bit)
- `ModelLoadError.directoryNotAccessible` — prevents crash when model directory is missing or deleted at load time

---

## Previous: tag-20260321 → tag-20260328

See git history for notes on: penalty processor GPU sync elimination (+35–65% token gen speed),
KV cache persistence API, multiple tool call fix, TopPSampler argPartition optimization.
