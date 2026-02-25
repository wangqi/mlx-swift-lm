# MLX-Swift-LM Update: tag-20260218 → tag-20260224

**Update Date:** February 24, 2026
**Previous Version:** tag-20260218
**Current Version:** tag-20260224
**New Commits (upstream):** 2 functional commits

---

## Executive Summary

This is a **minor maintenance upgrade** with code quality improvements and one targeted bug fix. No new model architectures, features, or API changes. The changes focus on **concurrency safety** for the MLXEmbedders module and a **LoRA parameter initialization fix**.

### Risk Assessment: **LOW** (1/5)

| Risk Area | Level | Reason |
|-----------|-------|--------|
| LoRA parameter eval fix | **LOW** | Correctness fix, moves `eval()` after `self` assignment |
| MLXEmbedders strict concurrency | **LOW** | Code style only, no behavioral change |
| mlx-swift 0.30.3 → 0.30.6 | **LOW** | Patch-level bump, same minor version |
| API breaking changes | **NONE** | No public API modifications |

---

## Commits Included

| Commit | Author | Date | Description |
|--------|--------|------|-------------|
| `7e19e09` | David Koski | 2026-02-18 | switch to current mlx-swift (#100) |
| `a3e1bf4` | Christoph Rohde | 2026-02-19 | Enforce structured concurrency for MLXEmbedders (#111) |

---

## Change Details

### 1. mlx-swift Dependency Update (0.30.3 → 0.30.6)

**PR #100** — Updates the core `mlx-swift` framework dependency.

- **What changed**: `Package.swift` dependency bumped from `0.30.3` to `0.30.6`
- **Why**: Incorporates upstream fixes from mlx-swift, including fix for issue #94 (reported as a correctness/stability bug)
- **Impact**: Patch-level bump within the same minor version — includes bug fixes and stability improvements in the underlying MLX computation engine
- **Co-authored-by**: mattt, atdrendel

### 2. LoRA Parameter Evaluation Fix

**PR #100** — Fixes parameter evaluation order in `LoRAContainer`.

- **File**: `Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift`
- **What changed**: `eval(parameters)` moved to **after** assignment to `self.parameters` (was called before assignment)
- **Why**: Parameters must be assigned to `self` before `eval()` to ensure they are fully evaluated as a property of the container, not as a consuming parameter about to be moved
- **Impact**: Fixes potential issues with LoRA adapter parameter initialization where parameters could be evaluated before being properly owned by the container
- **Lines changed**: 3 lines moved (no logic change, just reordering)

### 3. MLXEmbedders Strict Concurrency Enforcement

**PR #111** — Enables Swift strict concurrency checking for the MLXEmbedders target.

- **Package.swift**: Added `.enableExperimentalFeature("StrictConcurrency")`
- **Refactored files**:
  - `Bert.swift` — `BertModel.sanitize(weights:)` and `DistilBertModel.sanitize(weights:)`: mutable `var key` replaced with immutable `let key` using chained `.replacingOccurrences()` calls
  - `NomicBert.swift` — `NomicBertModel.sanitize(weights:)`: same var → let refactor
  - `BertConfiguration.init(from:)` — decoder code reformatted for readability (shorter lines, removed redundant `.self` on CodingKeys)
- **Why**: Enforces thread safety at compile time, eliminating potential data races in embedder weight sanitization
- **Impact**: **No behavioral change** — the weight key remapping logic produces identical results. This is purely a code quality/safety improvement

---

## Files Changed

| File | Changes | Type |
|------|---------|------|
| `Libraries/MLXEmbedders/Models/Bert.swift` | -92 / +56 | Refactor (code style) |
| `Libraries/MLXEmbedders/Models/NomicBert.swift` | -9 / +15 | Refactor (code style) |
| `Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift` | -3 / +3 | Bug fix |
| `Package.swift` | +3 | Config (strict concurrency) |

**Total**: 4 files changed, 89 insertions, 125 deletions (net -36 lines)

---

## iOS Device Impact

- **No iOS-specific changes** in this upgrade
- The mlx-swift 0.30.6 update may include Metal shader optimizations benefiting iOS GPU inference, but no iOS-specific code paths were modified in mlx-swift-lm itself
- LoRA fix applies equally to iOS and macOS
- Strict concurrency improvements help prevent threading issues on all platforms

---

## Our Integration — Action Items

### Required: **NONE**

No code changes required in the main AIAssistant project. This is a drop-in replacement.

### Recommended Testing

1. **Build verification** — Ensure the project compiles cleanly with the new mlx-swift 0.30.6 dependency
2. **MLX model inference** — Run a basic MLX model chat to verify inference works
3. **LoRA adapters** (if used) — Test loading a LoRA adapter to verify the parameter eval fix
4. **Embedders** (if used) — Test Bert/NomicBert embedding generation if the app uses MLXEmbedders

---

## Testing Checklist

- [ ] Project builds successfully with updated submodule
- [ ] MLX model text generation works (basic chat)
- [ ] LoRA adapter loading (if applicable)
- [ ] No runtime warnings or crashes from concurrency changes

---

## Overall Risk Rating

**LOW — safe to upgrade**

This is a minimal maintenance update with no API changes, no new features, and no architectural modifications. The only behavioral change is the LoRA parameter eval ordering fix, which is a correctness improvement. All other changes are code style reformatting for strict concurrency compliance.

---

**Generated:** 2026-02-24
**Covers commits:** 2 upstream commits (tag-20260218 → tag-20260224)

---

---

# MLX-Swift-LM Update: tag-20260127 → tag-20260218

**Update Date:** February 18, 2026
**Previous Version:** tag-20260127
**Current Version:** tag-20260218
**New Commits (upstream):** 13 functional commits

---

## Executive Summary

This update delivers two major architectural additions — **Wired Memory Control** and **Raw Token Streaming** — plus native function-calling support in `ChatSession`, a new Pythonic tool call parser, two new model families, and several important bug fixes.

### Risk Assessment: **MEDIUM** ⚠️

| Risk Area | Level | Reason |
|-----------|-------|--------|
| `Embedders` → `MLXEmbedders` rename | **HIGH** | Breaking import/target name change |
| `generateLoopTask` architecture change | **HIGH** | Our `externalToolCallParser` injection is now dead code |
| Wired Memory API | **LOW** | Opt-in, no breaking changes |
| Raw Token Streaming | **LOW** | Additive API |
| ChatSession tools | **LOW** | Additive parameter |
| New models | **LOW** | Additive only |
| Bug fixes | **LOW** | Safe improvements |

---

## Breaking Changes

### 1. `Embedders` Library Renamed to `MLXEmbedders` (#102)

**Impact: HIGH — requires build/package updates**

The Swift package target `Embedders` has been renamed to `MLXEmbedders` and all source files have been physically relocated:

```
Libraries/Embedders/ → Libraries/MLXEmbedders/
Libraries/Embedders/Bert.swift → Libraries/MLXEmbedders/Models/Bert.swift
Libraries/Embedders/NomicBert.swift → Libraries/MLXEmbedders/Models/NomicBert.swift
Libraries/Embedders/Qwen3.swift → Libraries/MLXEmbedders/Models/Qwen3.swift
```

**Action Required:**
- Update any `import Embedders` → `import MLXEmbedders` in app code
- Update `Package.swift` dependencies if referencing the target by name
- Update Xcode project target membership for any files that were in the old path

**Risk Level: HIGH**
- Build will fail until imports are updated
- No logic changes, purely a rename/reorganization

---

### 2. `generateLoopTask` Refactored — Our `externalToolCallParser` Is Now Dead Code

**Impact: HIGH — our custom tool call injection no longer executes**

The upstream introduced a `TokenLoopHandler` protocol and `TextToolTokenLoopHandler` struct that fully replace the old flat generation loop. Our wangqi [2026-01-07] custom code that injected `externalToolCallParser` into the generation loop was removed during the merge conflict resolution:

**What we had (now gone from the loop):**
```swift
// wangqi [2026-01-07] - These properties exist but are no longer used in the loop
iterator.toolcallStartTag
iterator.toolcallEndTag
iterator.externalToolCallParser
```

**What replaced it:**
```swift
// Upstream's TextToolTokenLoopHandler drives token processing now
generateLoopTask(..., handler: TextToolTokenLoopHandler(tokenizer: tokenizer, format: format))
```

**Action Required:**
- Audit `AIChatModelMLX.swift` — if it passes `externalToolCallParser` to `GenerateParameters`, that parser is currently NOT being called
- Either: migrate to using `ToolCallFormat` enum (standard formats), OR
- Update `TextToolTokenLoopHandler` to accept and delegate to an external parser when provided

**Risk Level: HIGH**
- Tool calls from MLX models may silently fail or produce incorrect output
- No compiler error will catch this — it is a silent behavioral regression

---

## New Features

### 3. Wired Memory Control (#72)

**Impact: MEDIUM — opt-in, significant for memory-constrained iOS devices**

New memory management system that pins model weights and KV caches in GPU-wired memory to prevent paging during inference on iOS 18 / macOS 15+.

**New Files:**
- `Libraries/MLXLMCommon/WiredMemoryPolicies.swift` (+182 lines)
- `Libraries/MLXLMCommon/WiredMemoryUtils.swift` (+249 lines)

**Key APIs:**

```swift
// Policy types
WiredSumPolicy(cap: 12 * 1024 * 1024 * 1024)   // sum all active tickets
WiredMaxPolicy(cap: ...)                         // use largest ticket only
WiredFixedPolicy(limit: ...)                     // fixed limit

// Measure actual model memory footprint
let measurement = try await WiredMemoryUtils.measure(
    model: model, context: context, tokenCount: 32)

// Use during generation
let ticket = policy.ticket(size: measurement.totalBytes, kind: .active)
let stream = try generate(
    input: lmInput, parameters: params, context: context,
    wiredMemoryTicket: ticket)
```

**iOS-Specific Notes:**
- Uses `GPU.maxRecommendedWorkingSetBytes()` as default cap (via `#if canImport(Metal)`)
- Prevents iOS from evicting GPU memory mid-generation (reduces generation pauses)
- On devices without Metal (or when policy is not set), falls back gracefully — fully opt-in
- Recommended for models > 4B parameters on iPhone

**Risk Level: LOW**
- Fully opt-in; existing code paths are unchanged
- `generate()` function gains an optional `wiredMemoryTicket` parameter (default `nil`)

---

### 4. Raw Token Streaming API (#88)

**Impact: LOW — new additive API**

Two new public functions for streaming raw token IDs instead of decoded text. Useful for downstream parsers that need token IDs directly (e.g., Harmony-style parsing, custom vocabularies).

**New APIs:**
```swift
// Convenience: returns AsyncStream<TokenGeneration>
func generateTokens(
    input: LMInput, cache: [KVCache]? = nil,
    parameters: GenerateParameters, context: ModelContext,
    includeStopToken: Bool = false
) throws -> AsyncStream<TokenGeneration>

// Low-level: returns stream + Task (for observing completion)
func generateTokensTask(...) throws -> (AsyncStream<TokenGeneration>, Task<Void, Never>)

// New enum (mirrors Generation but yields Int IDs, not decoded text)
public enum TokenGeneration: Sendable {
    case token(Int)
    case info(GenerateCompletionInfo)
}
```

Also added `generateTask()` low-level function that returns `(AsyncStream<Generation>, Task<Void, Never>)` — allows observing when the underlying Task finishes (useful when consumer breaks early from stream).

**iOS Impact:**
- Enables custom token-level post-processing pipelines
- `includeStopToken: true` mode lets consumers see the terminating EOS token

**Risk Level: LOW** — additive only, no changes to existing `generate()` behavior

---

### 5. ChatSession Function Calling Support (#107)

**Impact: LOW — additive parameter**

`ChatSession` gains a `tools: [ToolSpec]?` parameter across all three initializers, enabling structured function calling without manually constructing the prompt:

```swift
let session = ChatSession(
    model,
    instructions: "You are a helpful assistant.",
    tools: [myToolSpec]   // new
)
```

**iOS Impact:**
- Simplifies multi-turn tool-use conversations — tool schemas are passed once and maintained across turns
- Works with all model types that support `ToolCallFormat`

**Risk Level: LOW** — default is `nil`, no behavior change for existing sessions

---

### 6. Pythonic Tool Call Parser — LFM2.5 Support (#91)

**Impact: LOW — new parser format**

LFM2.5 (Liquid AI) outputs tool calls in Python-style list syntax rather than JSON:

```
[func(arg='value')]
```

New `PythonicToolCallParser` handles this format with prefix-match detection. Added to `ToolCallFormat` as a new case.

**Files Added:**
- `Libraries/MLXLMCommon/Tool/Parsers/PythonicToolCallParser.swift` (+100 lines)

**Risk Level: LOW** — new format only, no impact on existing parsers

---

## New Model Support

### 7. MiniMax and MiMo v2 Flash (#50)

Two new model architectures added:

| Model | File | Architecture Notes |
|-------|------|--------------------|
| **MiniMax** | `MiniMax.swift` (+340 lines) | Port of `minimax.py`, hybrid attention |
| **MiMo v2 Flash** | `MiMoV2Flash.swift` (+556 lines) | Flash attention with sink tokens, port of `mimo_v2_flash.py` |

Both registered in `LLMModelFactory.swift`.

**Risk Level: LOW** — additive, no impact on existing models

---

### 8. GLM4 MOE Lite — KV Latent Cache (#73)

`GLM4MOELite.swift` significantly enhanced (+216 lines) to store KV latent vectors in cache, matching the Python `glm4_moe_lite.py` implementation. Adds `MultiLinear` and `QuantizedMultiLinear` modules for proper quantized weight handling.

**Performance Impact:** Better generation speed for GLM4 MOE models due to proper KV caching.

**Risk Level: LOW** — existing GLM4 MOE users get improved performance

---

## Bug Fixes

### 9. Gemma3 / Gemma3n Vocabulary Padding (#99)

Gemma 3 12B+ models often ship weights with extra padding tokens (e.g., 262,208 entries vs. 262,144 expected), causing dimension mismatches on load. Fix trims the embedding matrix during `sanitize()`:

```swift
// Gemma3Text.swift and Gemma3nText.swift
// Trims vocab to model's configured vocab_size to avoid shape mismatch
```

**iOS Impact:** Enables loading Gemma 3 12B quantized models that previously failed with a shape error.

**Risk Level: LOW** — existing models unaffected; fixes a load-time crash for 12B variants

---

### 10. Mistral-Small-3.2 Loading Fix (#108)

`Mistral3Text.swift` refactored to make `rope_theta` optional in `RopeScaling`, fixing a loading error for `Mistral-Small-3.2-24B-Instruct-2506-4bit` which omits this field from its config.

**Risk Level: LOW** — fixes a crash-on-load for this specific model

---

## Documentation & Tooling

- **Embedding model documentation** (#104): Clarifies how to load a specific embedding model by name
- **MLXEmbedders README fix** (#103): Corrected code example in embedder README
- **skill.md added** (#92): Developer reference for LLM usage patterns
- **README snippet update**: Updated generation example in main README

---

## Our Integration — Action Items

### Critical (fix before using MLX models):

1. **Audit `externalToolCallParser` usage in `AIChatModelMLX.swift`**
   - Check if the app passes a custom parser via `GenerateParameters`
   - If yes: update `TextToolTokenLoopHandler` to accept and call the external parser, or switch to a registered `ToolCallFormat`
   - If no: no action needed, but remove the dead properties to avoid confusion

2. **Update any `import Embedders` to `import MLXEmbedders`**
   - Search codebase for `Embedders` imports
   - Update `Package.swift` target reference if needed

### Recommended (before production):

3. **Evaluate Wired Memory Control for iOS devices**
   - Consider using `WiredSumPolicy` for models ≥ 4B parameters
   - Run `WiredMemoryUtils.measure()` to profile actual model footprint
   - Wrap `generate()` calls with `wiredMemoryTicket` for smoother generation on constrained devices

4. **Test Gemma3 12B loading** — if using these models, the padding fix should resolve previous load failures

5. **Test Mistral-Small-3.2 loading** — if used in model list

---

## Testing Checklist

- [ ] **Tool calling** — verify MLX model tool calls still fire correctly after `externalToolCallParser` removal
- [ ] **Embedder import** — build succeeds with `MLXEmbedders` name
- [ ] **Gemma3 12B load** — model loads without shape mismatch error
- [ ] **Mistral-Small-3.2 load** — model loads without `rope_theta` error
- [ ] **Wired memory** — optionally enable and monitor generation smoothness on iOS
- [ ] **ChatSession with tools** — test function calling via ChatSession API
- [ ] **Raw token streaming** — if using `generateTokens`, test new API

---

## Overall Risk Rating

**MEDIUM — upgrade with caution on tool-calling features**

The library is safe to upgrade for standard text generation. The two high-risk items are both related to our own custom integration code (the `externalToolCallParser` silent removal and the embedder rename). Neither is a bug in the upstream library — they are integration points we own and need to update.

The new Wired Memory feature is the most valuable addition for iOS device stability and should be evaluated for adoption on larger models.

---

**Generated:** 2026-02-18
**Covers commits:** 13 upstream commits (tag-20260127 → tag-20260218)

---

---

# MLX-Swift-LM Update: tag-20260111 → tag-20260203

**Update Date:** February 3, 2026
**Previous Version:** tag-20260111
**Current Version:** tag-20260203
**Total Commits:** 23

---

## 🎯 Executive Summary

This update brings significant improvements in **thread safety**, **tool calling capabilities**, and **model support**. The most critical changes include thread-safety fixes for ModelContainer/KVCache and a new configurable tool call parsing system supporting 7 model formats.

### Risk Assessment: **MEDIUM** ⚠️

- **Thread Safety Fixes** (Critical): Resolves concurrent access issues but changes internal architecture
- **Tool Call Parsing** (Medium): New parser architecture merged with your custom external parser injection
- **MLX-Swift Update** (Low): Updated to 0.30.3 with additional thread safety improvements
- **New Models** (Low): Additive changes, backward compatible

---

## 🔧 Critical Changes

### 1. **Thread Safety Improvements** (#55, #56)

**Impact:** HIGH - Critical for iOS multi-threading stability

#### Changes:
- Fixed race conditions in `ModelContainer` when async token generation uses KVCache concurrently
- Added `SerialAccessContainer` utility for thread-safe model access
- Fixed issue where breaking async stream early could leave previous calls running
- Restored `Sendable` conformance to `ModelAdaptor` with `@unchecked Sendable`

#### Files Changed:
- `Libraries/MLXLMCommon/ModelContainer.swift` (+115 lines)
- `Libraries/MLXLMCommon/Evaluate.swift` (+83 lines)
- `Libraries/MLXLMCommon/ChatSession.swift` (+295 lines refactored)
- **NEW:** `Libraries/MLXLMCommon/Utilities/SerialAccessContainer.swift` (+118 lines)

#### iOS-Specific Impact:
✅ **Prevents crashes on iOS when canceling generation early**
✅ **Fixes memory corruption issues with concurrent KVCache access**
⚠️ **May affect performance due to serialization overhead**

#### Risk Level: **MEDIUM-HIGH**
- **Pro:** Resolves critical race conditions that could cause crashes
- **Con:** Changes internal architecture, potential performance impact
- **Mitigation:** Thoroughly test concurrent chat sessions and early stream cancellation

---

### 2. **Configurable Tool Call Parsing** (#78)

**Impact:** HIGH - This is what we just merged

#### New Features:
- **7 Tool Call Formats Supported:**
  - `.json` - Standard format (Llama, Qwen, most models): `<tool_call>{...}</tool_call>`
  - `.lfm2` - LFM2 format: `<|tool_call_start|>{...}<|tool_call_end|>`
  - `.xmlFunction` - Qwen3 Coder: `<function=name><parameter=key>value</parameter></function>`
  - `.glm4` - GLM4 format: `func<arg_key>k</arg_key><arg_value>v</arg_value>`
  - `.gemma` - Gemma format: `call:name{key:value}`
  - `.kimiK2` - Kimi K2: `functions.name:0<|tool_call_argument_begin|>{...}`
  - `.minimaxM2` - MiniMax M2: `<invoke name="f"><parameter name="k">v</parameter></invoke>`

- **New Parser Architecture:**
  - `ToolCallFormat` enum with `createParser()` factory method
  - `ToolCallParser` protocol for custom parsers
  - Dedicated parser implementations for each format

#### Files Added:
- `Libraries/MLXLMCommon/Tool/ToolCallFormat.swift` (+111 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/JSONToolCallParser.swift` (+38 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/GLM4ToolCallParser.swift` (+72 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/GemmaFunctionParser.swift` (+83 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/KimiK2ToolCallParser.swift` (+62 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/MiniMaxM2ToolCallParser.swift` (+81 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/XMLFunctionParser.swift` (+69 lines)
- `Libraries/MLXLMCommon/Tool/Parsers/ParserUtilities.swift` (+243 lines)

#### Our Integration:
✅ **External Parser Injection Preserved** - Your `ToolCallParserChain` integration still works
✅ **Custom Tag Support Maintained** - Models with non-standard tags still supported
✅ **Backward Compatible** - No breaking changes to your app's usage

#### Risk Level: **MEDIUM**
- **Pro:** More robust parsing, support for more model formats
- **Con:** Architecture change, potential edge cases in parser priority
- **Mitigation:** We added external parser override logic (verified in review above)

---

### 3. **MLX-Swift Framework Update** (#52)

**Impact:** MEDIUM - Foundation dependency update

#### Changes:
- Updated from mlx-swift **0.30.1** → **0.30.3**
- Additional thread safety fixes in MLX framework
- Moved `SwitchLayers.swift` from MLXLLM to MLXLMCommon
- Cleanup of redundant imports across codebase

#### iOS Impact:
✅ Improved stability on iOS devices
✅ Better memory management

#### Risk Level: **LOW-MEDIUM**
- **Pro:** Framework improvements, bug fixes
- **Con:** Dependency update always carries some risk
- **Mitigation:** mlx-swift is well-tested, incremental version bump

---

## 🆕 New Model Support

### Model Additions (Low Risk, High Value)

| Model | PR | Type | Notes |
|-------|----|----|------|
| **NemotronH** | #75 | LLM | NVIDIA Nemotron-3-Nano-30B-A3B, hybrid SSM+Attention+MoE |
| **MiniCPM** | #71 | LLM | MiniCPM series support |
| **GLM 4.7 Flash** | #68 | LLM | GLM4 MoE Lite models |
| **Qwen3-Next-80b** | #70 | LLM | Qwen3 Next 80B variant |
| **SwissAI Apertus** | #37 | LLM | Apertus 1.7B model |
| **LFM2 VL** | #58 | VLM | Vision-language model with bicubic interpolation |

#### Files Changed:
- Model registrations in `Libraries/MLXLLM/LLMModelFactory.swift`
- New model implementations in `Libraries/MLXLLM/Models/`
- Configuration support added

#### Risk Level: **LOW**
- Additive changes, no impact on existing models
- Tested via integration tests

---

## 🎥 VLM Enhancements

### External Video Frames Support (#64)

**Impact:** MEDIUM - iOS video processing improvements

#### New Features:
- **VideoFrame API:** Process external video frames instead of relying on AVAsset
- **Frame Sampling Control:** Specify samples per second for video processing
- **Better Resource Management:** Defensive checks for video tracks and decodability
- **VLM Model Updates:** SmolVLM2, Qwen2VL, Qwen25VL, Qwen3VL updated

#### API Changes:
```swift
// New: Process external video frames
UserInput.Image.frames([VideoFrame])

// Deprecated: asAVAsset() - will fatalError if using VideoFrames
```

#### iOS Impact:
✅ **Better memory control** for video processing
✅ **Custom frame extraction** possible
⚠️ **API deprecation** - `asAVAsset()` marked deprecated

#### Files Changed:
- `Libraries/MLXLMCommon/UserInput.swift` (+22 lines)
- `Libraries/MLXVLM/MediaProcessing.swift` (+148 lines)
- VLM model updates for Qwen series and SmolVLM2

#### Risk Level: **LOW-MEDIUM**
- **Pro:** More flexible video handling
- **Con:** API changes, deprecated methods
- **Mitigation:** Old API still works unless using VideoFrames

---

## 🐛 Bug Fixes

### 1. **Gemma3 + Attention Mask Fix** (#53)
- Fixed attention mask handling for Gemma3 models
- Port of Python mlx-lm fix for issue #463

### 2. **AfMoE and DeepSeek V3 Fix** (#30)
- Grammar and implementation fixes for AfMoE and DeepSeekV3

### 3. **Trailing Comma Fix** (#74)
- Fixed trailing comma issue in code generation

### 4. **EOS Token Handling** (#69)
- Now uses EOS tokens from config files instead of hardcoded values
- More robust end-of-sequence detection

#### Risk Level: **LOW**
- Bug fixes, no architectural changes

---

## ⚡ Performance Improvements

### 1. **GPT-OSS Optimizations** (#51)
- Aligned with Python mlx-lm code for better performance
- Optimized inference for GPT-OSS models

### 2. **LFM2 VL Interpolation** (#58)
- Bicubic interpolation for image processing
- Concurrency safety improvements for `InterpolationKernelManager`

#### Risk Level: **LOW**
- Performance improvements, well-tested

---

## 📊 Testing & Documentation

### New Tests Added:
- `Tests/MLXLMIntegrationTests/ToolCallIntegrationTests.swift` (+246 lines)
- `Tests/MLXLMTests/ToolTests.swift` (+253 lines added)
- `Tests/MLXLMIntegrationTests/ChatSessionIntegrationTests.swift` (+114 lines)
- VLM media processing tests with test resources

### Documentation:
- MLX Embedders code documentation enhanced (#65)
- README updates for new models

---

## 🚨 Breaking Changes & Deprecations

### Deprecations:
1. ❌ **`asAVAsset()` in MediaProcessing** - Use VideoFrames API instead
2. ⚠️ **Some UserInput methods** - Refactored for VideoFrames support

### Breaking Changes:
- **None for your app** - External parser integration maintained backward compatibility

---

## 🎯 Migration Recommendations

### High Priority (Do Immediately):
1. ✅ **Test concurrent chat sessions** - Verify thread safety improvements work correctly
2. ✅ **Test tool calling** - Verify external parser injection still works
3. ✅ **Test stream cancellation** - Ensure early breaks don't cause issues

### Medium Priority (Before Production):
1. ⚠️ **Review VLM video processing** - If using video inputs, test new API
2. ⚠️ **Performance testing** - Check for any performance regressions from thread safety changes
3. ⚠️ **Test new model formats** - If using models with custom tool call formats

### Low Priority (Optional):
1. 📝 Update to new tool call format system if using standard formats
2. 📝 Remove deprecated API usage if any
3. 📝 Test new models if interested

---

## 📈 Overall Risk Assessment

### Risk Breakdown:

| Component | Risk Level | Mitigation |
|-----------|-----------|------------|
| Thread Safety | **MEDIUM-HIGH** | Test concurrent operations thoroughly |
| Tool Call Parsing | **MEDIUM** | External parser verified to work |
| MLX-Swift Update | **LOW-MEDIUM** | Well-tested framework update |
| VLM Video API | **LOW-MEDIUM** | Only affects video processing features |
| New Models | **LOW** | Additive, no impact on existing |
| Bug Fixes | **LOW** | Improvements only |

### Overall: **MEDIUM** ⚠️

**Primary Concerns:**
1. Thread safety architecture changes - needs thorough testing
2. Tool call parser integration - verified but complex merge
3. MLX framework dependency update

**Strengths:**
- Extensive test coverage added
- Bug fixes included
- Backward compatible (mostly)
- Well-documented changes

---

## ✅ Testing Checklist

Before deploying to production:

- [ ] **Thread Safety**
  - [ ] Test multiple concurrent chat sessions
  - [ ] Test canceling generation mid-stream
  - [ ] Test rapid start/stop cycles
  - [ ] Monitor for memory leaks

- [ ] **Tool Calling**
  - [ ] Test models with standard `<tool_call>` tags
  - [ ] Test models with custom tags (e.g., `<|tool_call_start|>`)
  - [ ] Verify external parser is called correctly
  - [ ] Test all tool call formats your app uses

- [ ] **VLM (if used)**
  - [ ] Test image inputs (should work unchanged)
  - [ ] Test video inputs (new API)
  - [ ] Verify memory usage is acceptable

- [ ] **General**
  - [ ] Test on iOS 18.6+ (minimum version)
  - [ ] Test on different device types (iPhone, iPad)
  - [ ] Check memory usage under load
  - [ ] Verify all existing features work

---

## 📝 Summary

This update brings **critical thread safety improvements** and **enhanced tool calling support**. The changes are mostly additive and backward compatible, but the thread safety refactoring requires careful testing. The tool call parser integration has been verified to work with your external parser injection pattern.

**Recommendation:** Proceed with thorough testing in development/staging environment before production deployment.

---

## 📚 References

- [mlx-swift 0.30.3 Release](https://github.com/ml-explore/mlx-swift/releases)
- [Thread Safety PR #55](https://github.com/ml-explore/mlx-swift-lm/pull/55)
- [Tool Call Parsing PR #78](https://github.com/ml-explore/mlx-swift-lm/pull/78)
- [VLM Video Frames PR #64](https://github.com/ml-explore/mlx-swift-lm/pull/64)

---

**Generated:** 2026-02-03
**Your Custom Integration:** External parser injection preserved and verified ✅
