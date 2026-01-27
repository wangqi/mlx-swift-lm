# MLX Swift LM Upgrade Report: tag-20260111 → tag-20260127

## Executive Summary

**Upgrade Date**: 2026-01-27
**Commits**: 21 commits
**Files Changed**: 84 files (+30,865 lines, -7,295 lines)
**Overall Risk Level**: 🟡 **MEDIUM** (Thread safety fixes reduce risk, but API changes require testing)

---

## 🎯 Key Highlights

### ✅ Critical Improvements
- **Thread Safety Fixes** (#55, #56): Resolved concurrent access issues in KVCache and ModelContainer
- **Bug Fixes**: Fixed AfMoE, DeepSeek V3, and Gemma3 attention mask issues
- **Performance**: GPT-oss optimizations
- **Dependency Upgrade**: mlx-swift 0.30.2 → 0.30.3 with additional thread safety fixes

### 🆕 New Model Support
- NemotronH (NVIDIA-Nemotron-3-Nano-30B-A3B)
- Qwen3-Next-80b
- MiniCPM
- GLM 4.7 Flash (MoE)
- SwissAI Apertus 1.7B
- LFM2 VL (Vision-Language)

### 🔄 API Changes & Deprecations
- `asAVAsset()` marked as deprecated (VLM video processing)
- EOS tokens now loaded from config files (breaking change for custom configs)
- `ModelConfiguration.init` removed `eosTokenIds` parameter

---

## 📋 Detailed Changes

### 1. Thread Safety Improvements (⚠️ CRITICAL)

**Commits**: #55, #56
**Impact**: High - Fixes potential race conditions in async token generation

#### Changes:
- **KVCache Concurrency**: Fixed race condition where async token generation could access KVCache concurrently
- **ModelContainer Safety**: Added proper synchronization to prevent concurrent model access
- **Early Stream Break**: Fixed issue where breaking async stream early could leave previous call still running
- **ModelAdaptor Sendable**: Restored `Sendable` conformance with `@unchecked` after inspection
- **LoRAContainer**: Made thread-safe with proper state management

**iOS Impact**: ✅ **Positive** - Reduces crashes and undefined behavior in multi-threaded scenarios

**Code Locations**:
- `Libraries/MLXLMCommon/ModelContainer.swift` (+115/-0)
- `Libraries/MLXLMCommon/KVCache.swift` (+31/-0)
- `Libraries/MLXLMCommon/Adapters/ModelAdapter.swift`

---

### 2. New Model Architectures

#### NemotronH Support (#75)
**Files**: `Libraries/MLXLLM/Models/NemotronH.swift` (+1,003 lines)

**Components**:
- NemotronHConfiguration: Model config with Mamba2 + Attention + MoE hybrid
- NemotronHMamba2Mixer: State-space model block
- NemotronHAttention: Grouped-query attention with RoPE
- NemotronHMoE: Mixture-of-experts with sigmoid gating and shared experts
- NemotronHBlock: Pattern-based routing (Mamba/Attention/MoE)

**iOS Compatibility**: ✅ Full support (follows standard model pattern)

**Risk**: 🟢 **LOW** - New model, doesn't affect existing models

---

#### Qwen3-Next-80b (#70)
**Files**: `Libraries/MLXLLM/Models/Qwen3Next.swift` (+800 lines)

**Features**:
- 80B parameter model support
- Extended context window handling

**iOS Compatibility**: ✅ Full support (memory permitting)

**Risk**: 🟢 **LOW** - New model, optional usage

---

#### MiniCPM Support (#71)
**Files**: `Libraries/MLXLLM/Models/MiniCPM.swift` (+265 lines)

**iOS Compatibility**: ✅ Optimized for mobile devices (smaller model)

**Risk**: 🟢 **LOW** - New model, additive change

---

#### GLM 4.7 Flash MoE (#68)
**Files**: `Libraries/MLXLLM/Models/GLM4MOELite.swift` (+542 lines)

**Features**:
- Mixture-of-experts architecture
- Lite variant optimized for efficiency

**iOS Compatibility**: ✅ Full support

**Risk**: 🟢 **LOW** - New model, doesn't affect existing code

---

#### LFM2 VL Model (#58)
**Files**: `Libraries/MLXVLM/Models/LFM2VL.swift` (+1,283 lines)

**Features**:
- Vision-language model with bicubic interpolation
- `InterpolationKernelManager` with concurrency safety
- Image preprocessing with dynamic resolution

**iOS Compatibility**: ✅ Full support with iOS-optimized interpolation

**New Files**:
- `Libraries/MLXLMCommon/InterpolationUtils.swift` (+454 lines)

**Risk**: 🟢 **LOW** - New model, isolated implementation

---

### 3. VLM Video Frame Support (#64)

**Impact**: Medium - Major refactoring of video processing pipeline

#### New Features:
- `VideoFrame` promoted to `UserInput` type
- `asProcessedSequence()` function for converting video frame arrays to `ProcessedFrames`
- Support for external video frame arrays (not just AVAsset)
- Defensive checks for video track existence and decodability
- Configurable samples-per-second for frame extraction

#### API Changes:
- ✅ **New**: `UserInput.videoFrames([VideoFrame])`
- ⚠️ **Deprecated**: `asAVAsset()` - marked for removal, now raises `fatalError` with VideoFrames
- ✅ **New**: `asProcessedSequence(samplesPerSecond:)` - allows custom frame sampling rate

#### Models Updated:
- SmolVLM2
- Qwen2VL
- Qwen25VL
- Qwen3VL

**iOS Impact**: 🟡 **MEDIUM** - API changes may require updates if using VLM video processing

**Test Coverage**: ✅ Added `Tests/MLXLMTests/MediaProcessingTests.swift` with video resources

**Risk**: 🟡 **MEDIUM** - Breaking change if using deprecated `asAVAsset()`

**Migration Path**:
```swift
// Old (deprecated)
let asset = userInput.asAVAsset()

// New
let frames = try await userInput.asProcessedSequence()
```

---

### 4. Bug Fixes

#### AfMoE & DeepSeek V3 Fix (#30)
**Files**: `Libraries/MLXLLM/Models/AfMoE.swift`, `Libraries/MLXLLM/Models/DeepseekV3.swift`

**Issues Fixed**:
- Grammar issues in model implementation
- Inference accuracy problems

**iOS Impact**: ✅ **Positive** - Fixes potential incorrect outputs

**Risk**: 🟢 **LOW** - Bug fix, improves correctness

---

#### Gemma3 Attention Mask Fix (#53)
**Files**: `Libraries/MLXLLM/Models/Gemma3Text.swift`, `Libraries/MLXVLM/Models/Gemma3.swift`

**Issue**: Port of [mlx-lm#463](https://github.com/ml-explore/mlx-lm/issues/463) - attention mask handling after initial Swift port

**iOS Impact**: ✅ **Positive** - Fixes generation quality issues

**Risk**: 🟢 **LOW** - Bug fix for known issue

---

#### GPT-oss Performance Optimizations (#51)
**Files**: `Libraries/MLXLLM/Models/GPTOSS.swift` (+204/-0)

**Changes**: Aligned with Python reference implementation for better performance

**iOS Impact**: ✅ **Positive** - Faster inference

**Risk**: 🟢 **LOW** - Performance optimization

---

### 5. EOS Token Handling (#69)

**Breaking Change**: EOS tokens now loaded from config files

#### Changes:
- `ModelConfiguration.init` no longer accepts `eosTokenIds` parameter
- EOS tokens read from `generation_config.json` or model config files
- New `GenerationConfigFile` additions to support this

**Files Modified**:
- `Libraries/MLXLMCommon/ModelConfiguration.swift`
- `Libraries/MLXLMCommon/GenerationConfigFile.swift` (+16 lines)

**iOS Impact**: 🟡 **MEDIUM** - May break custom model configurations

**Risk**: 🟡 **MEDIUM** - Breaking change requiring config file updates

**Migration Path**:
```json
// Add to generation_config.json or model config
{
  "eos_token_id": 2,
  // or for multiple tokens
  "eos_token_id": [2, 128001, 128009]
}
```

---

### 6. Documentation & Code Quality

#### MLX Embedders Documentation (#65)
**Files**: `Libraries/Embedders/*.swift` (multiple files)

**Improvements**:
- Added comprehensive code documentation
- Consistent parameter descriptions
- Type and method descriptions
- Better code formatting with line wrapping

**iOS Impact**: 🟢 **Neutral** - Documentation only

**Risk**: 🟢 **NONE** - No functional changes

---

#### Test Infrastructure
**New Files**:
- `Tests/MLXLMTests/MediaProcessingTests.swift` (+128 lines)
- `Tests/MLXLMTests/NemotronHTests.swift` (+643 lines)
- `Tests/MLXLMTests/TestTokenizer.swift` (+148 lines)
- `Tests/MLXLMTests/Resources/` (video test assets)
- `Tests/MLXLMIntegrationTests/ChatSessionIntegrationTests.swift` (+114 lines)

**iOS Impact**: ✅ **Positive** - Better test coverage

**Risk**: 🟢 **NONE** - Test code only

---

### 7. Infrastructure Changes

#### GitHub Actions Split (#13)
**Files**: `.github/workflows/pull_request.yml` (+85/-0)

**Changes**: Split lint action for better CI performance

**iOS Impact**: 🟢 **Neutral** - CI only

---

#### MLX Swift Dependency Upgrade
**Version**: 0.30.2 → 0.30.3

**Changes**: Additional thread safety fixes in core mlx-swift library

**iOS Impact**: ✅ **Positive** - More stable threading

**Risk**: 🟢 **LOW** - Point release with bug fixes

---

### 8. Internal Refactoring

#### Utilities & Common Code
**New Files**:
- `Libraries/MLXLMCommon/Utilities/SerialAccessContainer.swift` (+118 lines) - Thread-safe container
- `Libraries/MLXLMCommon/InterpolationUtils.swift` (+454 lines) - Image interpolation utilities
- `Libraries/MLXLMCommon/JSONDecodingTypes.swift` (renamed from `StringOrNumber.swift`, +44 lines)

**Moved Files**:
- `SwitchLayers.swift`: `MLXLLM` → `MLXLMCommon` (better code organization)

**iOS Impact**: 🟢 **Neutral** - Internal refactoring

**Risk**: 🟢 **LOW** - Code organization, no API changes

---

## 🎯 Risk Assessment by Category

| Category | Risk Level | Reason |
|----------|-----------|--------|
| **Thread Safety** | 🟢 **LOW → SAFER** | Critical fixes reduce crash risk |
| **New Models** | 🟢 **LOW** | Additive, doesn't affect existing models |
| **VLM Video API** | 🟡 **MEDIUM** | Deprecated APIs may require migration |
| **EOS Token Config** | 🟡 **MEDIUM** | Breaking change for custom configs |
| **Bug Fixes** | 🟢 **LOW** | Improves correctness and performance |
| **Dependencies** | 🟢 **LOW** | Point release with stability fixes |
| **Overall** | 🟡 **MEDIUM** | Benefits outweigh risks, requires testing |

---

## ⚠️ Breaking Changes Summary

1. **EOS Token Configuration** (#69)
   - `ModelConfiguration.init` no longer accepts `eosTokenIds` parameter
   - Must provide EOS tokens in config files
   - **Action**: Update custom model configs with `eos_token_id` field

2. **VLM Video Processing** (#64)
   - `asAVAsset()` deprecated (fatalError with VideoFrames)
   - **Action**: Migrate to `asProcessedSequence()` if using VLM video features

---

## ✅ Recommended Actions

### High Priority (Before Production)
1. ✅ **Test Thread Safety**: Run concurrent inference tests to validate fixes
2. ✅ **Update Model Configs**: Add `eos_token_id` to any custom model configurations
3. ✅ **VLM Video Migration**: If using VLM video features, migrate from `asAVAsset()` to `asProcessedSequence()`
4. ✅ **Regression Testing**: Test existing models (especially AfMoE, DeepSeek V3, Gemma3)

### Medium Priority (Before Release)
1. 🔶 **Performance Validation**: Benchmark inference speed with new GPT-oss optimizations
2. 🔶 **New Model Testing**: If planning to use new models (NemotronH, Qwen3-Next-80b, etc.), validate on iOS devices
3. 🔶 **Memory Testing**: Verify memory usage with new LFM2 VL model and interpolation utilities

### Low Priority (Nice to Have)
1. 🔹 **Documentation Review**: Review new embedders documentation
2. 🔹 **Test Coverage**: Review new test files for reference implementations
3. 🔹 **CI Pipeline**: Monitor split lint actions for faster CI feedback

---

## 📊 Impact on iOS Devices

### Performance Impact
- ✅ **Improved**: GPT-oss optimizations
- ✅ **Improved**: Thread safety fixes reduce overhead
- 🔶 **Neutral**: New models (optional usage)
- 🔶 **Potential**: Interpolation utils may increase memory for LFM2 VL

### Memory Impact
- 🔶 **Neutral to Slight Increase**: New models add binary size
- ✅ **Improved**: Thread safety fixes reduce memory leaks
- 🔶 **Monitor**: LFM2 VL with bicubic interpolation (image preprocessing)

### Stability Impact
- ✅ **Significantly Improved**: Thread safety fixes (#55, #56)
- ✅ **Improved**: Bug fixes for AfMoE, DeepSeek V3, Gemma3
- 🔶 **Requires Testing**: EOS token config changes

---

## 🚀 New Capabilities for iOS

1. **Video Frame Processing**: External video frame arrays for VLM models
2. **More Model Choices**: 6 new model architectures (NemotronH, Qwen3-Next, MiniCPM, GLM4, Apertus, LFM2 VL)
3. **Better Concurrency**: Safer async token generation
4. **Improved Generation**: Better EOS token handling from config files

---

## 📝 Migration Checklist

- [ ] Review EOS token configuration for all custom models
- [ ] Test concurrent inference scenarios
- [ ] Migrate VLM video code from `asAVAsset()` to `asProcessedSequence()` (if applicable)
- [ ] Run regression tests on existing models
- [ ] Validate memory usage on target iOS devices
- [ ] Update documentation if exposing VLM video features
- [ ] Test new models if planning to integrate (optional)

---

## 🔗 References

- **Upstream Repository**: [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
- **MLX Swift**: [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) (v0.30.3)
- **Related Issues**:
  - Thread safety: [#54](https://github.com/ml-explore/mlx-swift-lm/issues/54)
  - Gemma3 attention: [#27](https://github.com/ml-explore/mlx-swift-lm/issues/27)
  - Python MLX issue: [mlx-lm#463](https://github.com/ml-explore/mlx-lm/issues/463)

---

## 📈 Statistics

```
Total Commits: 21
Files Changed: 84
Insertions: +30,865 lines
Deletions: -7,295 lines
Net Change: +23,570 lines

Breakdown by Library:
- MLXLLM: 15 files (+3,526 lines) - New models and fixes
- MLXVLM: 10 files (+1,547 lines) - Video frame support + LFM2 VL
- MLXLMCommon: 20 files (+1,023 lines) - Thread safety + utilities
- Embedders: 10 files (+213 lines) - Documentation
- Tests: 8 files (+1,240 lines) - New test coverage
```

---

## ✍️ Conclusion

This upgrade brings **critical thread safety improvements** and **bug fixes** that enhance stability on iOS devices. The new model support is additive and optional. The main areas requiring attention are:

1. **EOS token configuration** (breaking change)
2. **VLM video API migration** (if used)
3. **Thorough testing** of concurrent scenarios

**Recommendation**: ✅ **PROCEED with upgrade** after completing migration checklist and testing. The thread safety fixes alone justify the upgrade, and breaking changes are manageable with clear migration paths.

**Estimated Effort**:
- Migration: 2-4 hours (config updates + VLM API changes if used)
- Testing: 4-8 hours (concurrent scenarios + regression testing)
- Total: 6-12 hours

**Risk vs. Reward**: Thread safety improvements and bug fixes outweigh the moderate risk from API changes. This is a **net positive** upgrade for iOS stability.
