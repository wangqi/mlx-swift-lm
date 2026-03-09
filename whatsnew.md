# MLX-Swift-LM Upgrade: tag-20260302 to tag-20260309

## Summary

11 commits merged from upstream `ml-explore/mlx-swift-lm`. Key themes:
**Qwen3.5 vision support, tool-call reliability, RoPE consolidation, JSON5 config parsing, and Swift Concurrency cleanup.**

---

## New Features

### Qwen3.5 Vision-Language Models (VLM)
- **Commit**: `7da3344` — Adding Support for Qwen3.5 and Qwen3.5 MoE (Vision)
- Full Qwen3.5 VLM implementation added (`MLXVLM/Models/Qwen35.swift`, 1252 lines)
- Qwen3.5 MoE vision variant added (`MLXVLM/Models/Qwen35MoE.swift`)
- Registered in `VLMModelFactory.swift` (two new model type entries)
- **Impact**: iPhone/iPad users can now run Qwen3.5 vision models locally via MLX

### Qwen3.5 Text-Only Model Type Registration Fix
- **Commit**: `06bfeed` — Add qwen3_5_text model type support
- Registers `qwen3_5_text` in `LLMTypeRegistry` using `Qwen35TextConfiguration` / `Qwen35TextModel`
- Fixes: "Unsupported model type: qwen3_5_text" crash when loading text-only Qwen 3.5 models
- **Impact**: Critical fix for any user loading Qwen 3.5 text models on iOS

### JSON5 Config Support
- **Commit**: `3a7f2b1` — Add JSON5 support
- New `JSONDecoder+JSON5.swift` extension; `MLXEmbedders`, `MLXLLM`, and `MLXVLM` factories all use JSON5 parsing
- Allows comments and trailing commas in `config.json` / `tokenizer_config.json`
- **Impact**: Broader compatibility with HuggingFace model configs that use JSON5 conventions

### Optional Tool-Call Dispatch and Output Injection
- **Commit**: `0840626` — add optional toolCall dispatch and tool output injection
- `ChatSession.swift` refactored to support optional tool-call handler dispatch and injecting tool outputs back into the generation stream
- Enables frameworks built on `ChatSession` to handle tool calls natively without re-implementing session state

---

## Bug Fixes

### XML Function Parser: Newline Support for Tool Calls
- **Commit**: `e33eba8` — Fix XMLFunctionParser regex to match newlines
- Swift/ICU regex `.` does not match `\n`; replaced with `[\s\S]` (equivalent to Python `re.DOTALL`)
- Models like Qwen3.5 generate newlines between XML function tags, causing silent parse failures
- **Impact**: Tool calls from Qwen3.5 now parse correctly; previously they were silently dropped

### Qwen3VL: Pass additionalContext Correctly
- **Commit**: `0ef0e10` — Pass additionalContext to Qwen3VL
- `Qwen3VL.swift` was not forwarding `additionalContext` to the generation pipeline
- **Impact**: Multi-turn Qwen3 VL conversations now receive correct context

### RoPE Configuration Audit (30 files)
- **Commit**: `6bb84aa` — audit RoPE use across models
- Unified RoPE layer implementation across 25+ models (Llama, Qwen, OLMo, OLMoE, DeepSeek V3, Mistral 3, Granite, etc.)
- Fixed bugs in RoPE config decoding; models now match upstream Python `mlx-lm` behavior
- New `RoPELayer` / `ArrayOffsetLayer` protocol for cleaner batch RoPE API
- Net code reduction: 901 lines removed, 248 added
- **Impact**: Fixes potential numerical differences; improves generation correctness for affected model families

### Qwen3.5 Performance Optimization
- **Commit**: `1062897` — Qwen3.5 performance optimization
- `GatedDelta` layer extracted from `Qwen3Next.swift` into shared `GatedDelta.swift`
- Reduces duplication between `Qwen3Next` and `Qwen35`

---

## Maintenance

### Swift Concurrency / Sendable Cleanup
- **Commit**: `6d36ed9` — fix Sendable issues, unused code, deprecation warnings
- Fixed `@Sendable` conformance gaps in `ModelContainer`, tool parsers, and VLM models
- **Impact**: Cleaner compiler output; reduces data-race warnings on Swift 6

### swift-transformers 1.1.9 Dependency Bump
- **Commit**: `a7be758` — Pick up swift-transformers 1.1.9
- Picks up tokenizer fixes from the swift-transformers library

---

## Risk Assessment

| Area | Risk Level | Notes |
|------|-----------|-------|
| RoPE audit (30 files) | **Medium** | Large refactor across 25+ models. Generation quality may differ slightly; unlikely to crash. Test Llama, Qwen3, DeepSeek V3, OLMo 2 after upgrade. |
| Qwen3.5 text type fix | **Low** | Additive registration fix; other models unaffected. |
| Qwen3.5 VLM | **Low** | New code path; existing VLM models unchanged. |
| XMLFunctionParser fix | **Low** | Regex-only change; adds newline support without breaking other models. |
| JSON5 support | **Low** | Additive; falls back gracefully if no JSON5 features used. |
| ChatSession tool dispatch | **Low-Medium** | Refactored existing `ChatSession`; integration tests added. |
| swift-transformers bump | **Low** | Minor version bump with tokenizer fixes. |
| Sendable cleanup | **Low** | No behavioral change expected. |

**Overall upgrade risk: LOW-MEDIUM.** The RoPE audit touches the most files but is well-validated upstream. The Qwen3.5 text model type fix and XML tool-call parser fix are important correctness improvements.
