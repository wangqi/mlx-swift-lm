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
