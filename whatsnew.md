# mlx-swift-lm: tag-20260425 → tag-20260509

## Summary

Two commits merged from upstream `ml-explore/mlx-swift-lm` between April 25 and May 9, 2026. The update is a targeted bug-fix release paired with an expanded integration-test suite. No new model architectures, no API changes, no dependency version bumps.

---

## Changes

### Bug Fix: Qwen3.5 VLM crash on text-only inference (PR #149)

**Commit:** `3e2ddb4` — David Irvine, 2026-05-07

**Problem:** `Qwen35Language.LanguageModel.callAsFunction` assumed its `inputs` tensor was always 2-D `[batch, seq]`. Text-only callers — `WiredMemoryUtils.tune` and `TokenIterator` — can legally pass a 1-D `[seq]` array. When that happened, `getRopeIndex()` and every subsequent `dim(1)` call crashed with a **SmallVector out-of-range** panic (issue #148).

**Fix:** A one-line ndim guard is inserted at the top of `callAsFunction`:

```swift
let inputs = inputs.ndim == 1 ? inputs.expandedDimensions(axis: 0) : inputs
```

This reshapes 1-D inputs to `[1, seq]` before any dimension-dependent logic runs. 2-D inputs are left unchanged.

**File changed:** `Libraries/MLXVLM/Models/Qwen35.swift`

**iOS Impact:** Positive — Qwen3.5 VLM models (e.g., `Qwen3.5-VL-2B-Instruct-4bit`) no longer crash when used in text-only mode. Previously, sending a plain text message to a Qwen3.5 VLM container could trigger this panic during `WiredMemoryUtils` wired-memory tuning or on the first token-iterator call.

---

### Test Infrastructure: Coherence Integration Tests (PR #235)

**Commit:** `38fff58` — Anthony DePasquale, 2026-05-08

**Added:** `IntegrationTesting/IntegrationTestingTests/CoherenceIntegrationTests.swift`

A new `@Suite(.serialized)` test suite that runs a planet-naming coherence prompt against 18 model families to verify end-to-end generation correctness:

| Model | Registry Key |
|-------|-------------|
| BitNet b1.58 2B | `LLMRegistry.bitnet_b1_58_2b_4t_4bit` |
| EXAONE 4.0 1.2B | `LLMRegistry.exaone_4_0_1_2b_4bit` |
| Gemma 3 1B QAT | `LLMRegistry.gemma3_1B_qat_4bit` |
| Gemma 3n E2B | `LLMRegistry.gemma3n_E2B_it_lm_4bit` |
| Gemma 4 E2B | `LLMRegistry.gemma4_e2b_it_4bit` |
| GLM4 9B | `LLMRegistry.glm4_9b_4bit` |
| Granite 3.3 2B | `LLMRegistry.granite3_3_2b_4bit` |
| Granite 4.0-H Tiny | `LLMRegistry.granite_4_0_h_tiny_4bit_dwq` |
| Jamba 3B | `LLMRegistry.jamba_3b_4bit` |
| LFM2 1.2B | `LLMRegistry.lfm2_1_2b_4bit` |
| Llama 3.2 1B | `LLMRegistry.llama3_2_1B_4bit` |
| Mistral 7B | `LLMRegistry.mistral7B4bit` |
| OLMo2 7B | `LLMRegistry.olmo_2_1124_7B_Instruct_4bit` |
| OLMoE 1B×7B | `LLMRegistry.olmoe_1b_7b_0125_instruct_4bit` |
| Phi 3.5 | `LLMRegistry.phi3_5_4bit` |
| Qwen3 1.7B | `LLMRegistry.qwen3_1_7b_4bit` |
| Qwen3.5 2B | `LLMRegistry.qwen3_5_2b_4bit` |
| SmolLM3 3B | `LLMRegistry.smollm3_3b_4bit` |

**Refactored:** `ToolCallIntegrationTests.swift` — model-specific container helper methods (`lfm2Container()`, `glm4Container()`, etc.) replaced with the unified `llmContainer(for:)` call, consolidating Task lifecycle management in one place.

**iOS Impact:** None on production code. Test-only change that indirectly validates iOS-runnable model families.

---

## Risk Assessment

| Area | Risk | Rationale |
|------|------|-----------|
| Qwen3.5 VLM fix | **Low** | Single defensive guard at function entry; only affects previously-crashing code paths. 2D inputs pass through unchanged. |
| Coherence test suite | **None** | Test-only code, not compiled into the app target. |
| API surface | **None** | No public API changes. |
| Other model families | **None** | Changes are isolated to `Qwen35.swift`; no shared infrastructure modified. |
| Dependency versions | **None** | No package version bumps in this range. |

**Overall upgrade risk: LOW.** The only production change is a crash fix. Rolling back would re-expose the Qwen3.5 VLM text-only crash.

---

## Recommended Actions

1. Run `ToolRunShellTests` and any local MLX model tests to confirm no regressions.
2. Verify Qwen3.5 VL models load and respond to text-only prompts without crashing on device.
3. No config, JSON, or localization changes required.
