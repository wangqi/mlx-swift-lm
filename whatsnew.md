# MLX Swift LM — What's New (tag-20260419)

Upgrade window: **tag-20260412 → tag-20260419**  
13 commits merged from upstream `ml-explore/mlx-swift-lm`.

---

## New Features

### Gemma 4 Text-Only Architecture (E2B and E4B) — #185
Full port of `gemma4.py` / `gemma4_text.py` from mlx-lm. Enables on-device inference of Google Gemma 4's text-only variant on Apple Silicon via MLX.

Key architectural additions:
- **Per-Layer Embeddings (PLE)** with gated residual
- **Shared KV cache** across later layers (reduces memory pressure)
- **Dual RoPE**: proportional RoPE for full-attention layers, default RoPE for sliding-window layers
- **ProportionalRoPE** with `partial_rotary_factor` support
- **Global head dimensions** (512) for full-attention layers
- **Double-wide MLP** for KV-shared layers
- **Logit softcapping**
- **LoRA adapter support**

Registers `gemma4` and `gemma4_text` model types with E2B/E4B 4-bit configs. Fixes model IDs, weight key mapping, and EOS token (`<turn|>`, token ID 106).

> **iOS impact**: E2B (~2 GB at 4-bit) is feasible on iPhone 15 Pro/16 series; E4B (~4 GB) needs 8 GB RAM (M-series iPads or iPhone 16 Pro Max).

---

### Gemma 4 Batched RoPE Offsets — #212
Adds `Gemma4PositionOffset` and a `BatchPositionedKVCache` stub in preparation for multi-image / multi-turn batching. The attention path now accepts per-batch positional offsets, enabling future speculative decoding and multi-image prompt caching for Gemma 4.

---

### Embedder API Unified with LLM/VLM Factory — #202
`MLXEmbedders` module refactored to reuse the same `ModelFactory`, `ModelTypeRegistry`, `AbstractModelRegistry`, and loading/download pipeline as `MLXLLM`/`MLXVLM`.

**Removed files** (breaking for direct importers):
- `BaseConfiguration.swift`
- `Configuration.swift`
- `Load.swift`
- `Models.swift`

**New files**:
- `EmbedderModelContainer.swift` — unified container matching `LLMModelContainer`
- `ModelFactory.swift` — factory conforming to shared `AbstractModelFactory`

> **Migration**: Replace any direct `Load.swift` embedder calls with the new factory pattern.

---

## Bug Fixes

### Gemma 4 System Message and Modality Order — #211
Corrects two Gemma 4 VLM issues:
1. System messages were not being passed correctly to the chat template.
2. Content type ordering was wrong — images must precede text in the multimodal content array per Gemma 4's template.

> **iOS impact**: Without this fix, Gemma 4 VLM responses would ignore system prompts and multi-modal prompts could produce garbled output.

---

### KV Cache Prompt-Cache Round-Trip — #155
Fixes `save`/`restore` support for `ArraysCache`, `MambaCache`, and `CacheList`. Previously these cache types silently no-op'd on restore (the NOP was replaced with `assertionFailure`), so prompt-cache acceleration had no effect for Mamba/SSM-hybrid models.

176 new unit tests added in `KVCacheTests.swift` covering all cache variants.

> **iOS impact**: Prompt cache now actually works for Mamba and hybrid models, reducing TTFT on repeated/similar prompts.

---

### Qwen3 Next Tool Call Format — #166
`ToolCallFormat.infer()` now recognises `qwen3_next` (and variants) as `xmlFunction` format. Previously tool calls from Qwen3-Next models were silently dropped because the model type was not matched.

> **iOS impact**: Qwen3 Next models (e.g. Qwen3-Next-4B) can now invoke tools correctly in agentic workflows.

---

### BERT Embedder Safety Guard for Long Inputs — #163
BERT models crash with an out-of-bounds error when input token count exceeds `maxPositionEmbeddings` (the position embedding table is fixed-size). This is now guarded: inputs are truncated with a warning and the new `maxPositionEmbeddings` property is exposed on `EmbeddingModel` so callers can pre-check or chunk.

> **iOS impact**: Prevents hard crashes when embedding long documents or memory entries via BERT-family models.

---

## API / Infrastructure Changes

### v3 API Small Fixes — #190
- Jinja template files are now downloaded in all loading paths (previously missed in some routes, causing template evaluation failures).
- HuggingFace macros (`MLXHuggingFace`) now emit fully qualified type names, fixing compilation in multi-module setups.

### swift-syntax Dependency Tightened — #216
Range changed from `from: "600.0.0-latest"` to `"600.0.0" ..< "604.0.0"` to prevent unintentional pulls of incompatible swift-syntax 604+ releases during `swift package update`.

---

## Documentation

- **Upgrade guide** (`upgrade.md`): Step-by-step 2.x → 3.x migration.
- **Using guide** (`using.md`): Integration package selection, quick-start code.
- **Developing guide** (`developing.md`): How to contribute / port new model architectures.
- Fallback source links added to README for SPI 404 cases.

---

## Upgrade Risk Assessment

| Area | Risk | Notes |
|------|------|-------|
| `MLXEmbedders` API | **Medium** | Breaking refactor removes 4 files; update all embedder load callsites |
| Gemma 4 VLM messages | **Low** | Correctness fix; regression only if code bypassed `Gemma4MessageGenerator` |
| KV Cache save/restore | **Low** | Additive; new `assertionFailure` may surface previously silent bugs in tests |
| Tool call format | **Low** | Additive; no existing call sites broken |
| BERT input guard | **Low** | Truncation instead of crash; semantic output may differ for very long inputs |
| swift-syntax constraint | **Low** | Build-time only; no runtime change |
| Gemma 4 text models | **Low** | New model type; no impact on existing model loading |

**Overall risk: Low-Medium.** The only breaking change is the `MLXEmbedders` API refactor. Verify all embedder call sites compile after merge.

---

## Local Fork Notes (wangqi)

- `Libraries/MLXVLM/Models/Gemma4.swift`: Conflict resolved -- tool-call merging loop preserved on top of the new `Gemma4MessageGenerator()` (replaces the old `Qwen2VLMessageGenerator()` placeholder). The loop is still required because Gemma 4's Jinja template expects tool responses inside the same assistant message.
- `Libraries/MLXLMCommon/Chat.swift`: `generate(messages:)` override with tool-field injection and debug logging retained (wangqi 2026-03-10).
