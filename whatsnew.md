# MLX Swift LM - What's New

## tag-20260321 (2026-03-21)

### Changes from tag-20260315 to tag-20260321

**Fix: LFM2 Tool Calling with Nested Parentheses (#152)**
`PythonicToolCallParser` was rewritten to handle nested parentheses in tool-call arguments (e.g. `func(arg="value(with parens)")`). The old `.*?` non-greedy regex failed when argument values contained parentheses, silently returning `nil` instead of a parsed tool call.

New strategy:
1. **Bracket pattern first**: `\[(\w+)\((.*?)\)\]` — the required closing `\]` forces the lazy `.*?` to backtrack past any inner `)`, correctly capturing the full argument string.
2. **Index-based fallback**: For bracket-less format (e.g. `func(args...)`), uses `firstIndex(of: "(")` + `lastIndex(of: ")")` to find the outermost parentheses, avoiding the greedy/non-greedy pitfall entirely.

**Fix: Quantized BERT / NomicBert Embedding Models Crash (SIGABRT) (#153)**
Two distinct bugs fixed in `Bert.swift` and `NomicBert.swift`:

1. **SIGABRT on load** — `BertModel.pooler` and `NomicBertModel.pooler` (both `Linear?`) were not annotated with `@ModuleInfo`. During quantization, `Module.update(modules:)` replaces them with `QuantizedLinear` via the non-throwing wrapper, which internally uses `try!`. Without `@ModuleInfo`, the module lookup throws `needModuleInfo`, causing `try!` to crash with SIGABRT.
   - Fix: Added `@ModuleInfo` to both `pooler` properties.

2. **Fatal error: mask dtype mismatch** — The attention mask was cast to `embedder.wordEmbeddings.weight.dtype` (always `float32` since `Embedding` layers are unquantized). When Q/K/V projections were quantized to `float16`, `MLXFast.scaledDotProductAttention` required the mask to match the output dtype (`float16`). A `float32` mask cannot promote down to `float16`, causing a fatal error.
   - Fix: Cast the attention mask to `embeddings.dtype` (computed after the embedding forward pass), which reflects the actual compute dtype flowing into the encoder.

**New: Gemma 3 Embedding Model (#136)**
Full Gemma 3 embedding model implementation added to `MLXEmbedders`:
- New file `Gemma3.swift` (~496 lines) with full encoder architecture
- `l2Normalized()` helper added to `MLXArray`
- Model aliases registered: `gemma3`, `gemma3_text`, `gemma3n`
- `EmbeddingModel` properties made publicly readable
- Integration tests added

---

### Risk Assessment

| Change | Risk Level | Rationale |
|--------|-----------|-----------|
| LFM2 tool calling parser rewrite | Low | Bug fix only; other parsers (JSON, XML) untouched; LFM2-specific path; added tests cover the fixed cases |
| BERT/NomicBert SIGABRT fix | Low | Pure bug fix; `@ModuleInfo` annotation is additive; dtype fix only affects quantized float16 models, which previously crashed on load |
| Gemma 3 embedding model | Low | Additive only; new file behind factory registration; no changes to existing model paths |

**Overall Upgrade Risk: Low**
All three changes are targeted bug fixes or purely additive new model support. No breaking API changes. Quantized BERT/NomicBert embedding models that previously crashed will now load and run correctly — this is a material improvement for any user running those models on-device. Recommend smoke-testing LFM2 tool calling and any BERT-based embedding flows after upgrade.

---

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
