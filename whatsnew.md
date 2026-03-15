# MLX Swift LM - What's New

## tag-20260315 (2026-03-15)

### Changes from tag-20260309 to tag-20260315

**New: GLM-OCR Vision-Language Model Support**
A full GLM-OCR model implementation (`GlmOcr.swift`, ~1262 lines) was added to the MLXVLM library. GLM-OCR is a vision-language model optimized for OCR and document understanding tasks. It is registered in `VLMModelFactory` and available for on-device inference on iPhone/iPad with Apple Silicon.

**Enhancement: Expanded Sampling Parameters in GenerateParameters**
`GenerateParameters` gained five new sampling controls:
- `topK` (Int, default 0): Top-K filtering — keeps only the K most likely next tokens before sampling.
- `minP` (Float, default 0.0): Min-P filtering — removes tokens whose probability falls below `minP * max_prob`.
- `presencePenalty` / `presenceContextSize`: Additive penalty for any token that has appeared in the recent context window, discouraging repetition of topics.
- `frequencyPenalty` / `frequencyContextSize`: Additive penalty that scales with how many times a token has appeared in the recent context, suppressing high-frequency tokens.

`TopPSampler` was updated to accept and apply all three probability filters (topP, topK, minP) in combination. `processor()` now returns a unified `PenaltyProcessor` that combines repetition, presence, and frequency contexts when any are active.

**Fix: Tool Calling for Qwen3.5**
Qwen3.5 tool calling was broken. This update adds:
- Prefix matching for flexible/incremental parsing of tool-call syntax
- A pythonic tool converter (aligned with Qwen3.5 chat template expectations)
- VLM-level detection for Qwen3.5 tool-call output
- Nemotron model support added alongside the Qwen3.5 changes

**Fix: Tool Calling for Mistral 3**
Full tool-calling support was added for Mistral 3, including integration tests to validate the end-to-end flow.

**Fix: LFM2.5 VL Tools**
LFM2.5 VL's chat template was not receiving the tools list from the generation request, so tool calls were never triggered. The tool list is now correctly passed through.

---

### Risk Assessment

| Change | Risk Level | Rationale |
|--------|-----------|-----------|
| GLM-OCR new model | Low | Additive only; no changes to existing model paths; new Swift file behind factory registration |
| GenerateParameters expansion | Low-Medium | Additive API: all new params have safe defaults (0 / nil = disabled). Existing callers unaffected. The `processor()` function was refactored to return a new `PenaltyProcessor` type — callers that pattern-match on `RepetitionContext` specifically may break. |
| `TopPSampler` signature change | Low-Medium | New optional parameters with defaults; existing `TopPSampler(temperature:topP:)` calls still compile. The sampler activation logic changed: topK or minP alone now triggers `TopPSampler` even when topP==1.0 (previously only `CategoricalSampler` was used). |
| Qwen3.5 tool calling fix | Low | Bug fix; only activates for Qwen3.5-detected models; other models unaffected |
| Mistral 3 tool calling | Low | New capability for an existing model family; no regressions expected |
| LFM2.5 VL tools fix | Low | Single-line bug fix in template context passing |

**Overall Upgrade Risk: Low**
All changes are either purely additive or targeted bug fixes. No breaking API changes affect our current usage. The primary integration point is `GenerateParameters`, and since our app constructs it with named parameters, the new fields (all defaulted) are invisible to existing call sites. Recommend testing Qwen3.5 and Mistral 3 tool-calling flows after upgrade.
