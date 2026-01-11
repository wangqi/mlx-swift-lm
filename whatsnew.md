# MLX Swift LM Upgrade Report
**Version:** tag-20251226 → tag-20260111
**Date:** 2026-01-11
**Total Commits:** 13

## Executive Summary

This upgrade brings significant new features, performance improvements, and critical bug fixes. The changes primarily focus on expanding model support (especially vision-language models), optimizing model loading performance, and fixing configuration parsing issues that previously caused crashes.

**Overall Risk Level:** 🟡 **Medium-Low**

---

## 🎯 New Features

### 1. Vision-Language Model Support (Ministral 3/Pixtral)
**Commit:** `c8440b4` - Add Ministral 3 with vision (Pixtral) (#18)

**Changes:**
- Added complete support for Ministral 3 multimodal models
- New VLM architecture with 1,109 lines of Mistral3.swift
- New Pixtral vision encoder with 1,137 lines
- Moved RoPEUtils and SuScaledRoPE to MLXLMCommon for shared use
- Updated RoPE implementation for Mistral 3

**iOS Impact:** ✅ Positive
- Enables multimodal AI capabilities on iOS
- Vision-language models can process images natively
- All implementation is pure Swift/MLX (iOS-compatible)

**Risk:** 🟡 Medium
- Large new codebase (2,200+ lines) increases testing surface
- Processor config loading changed (prefers preprocessor_config over processor_config)
- May require vision model weights not yet in your model catalog

---

### 2. GLM 4.7 Model Support
**Commit:** `1f720d8` - Add GLM 4.7 model (#48)

**Changes:**
- Added GLM4MOE (Mixture of Experts) architecture
- 453 lines of new model code
- Fixed QK norm order
- Updated README with GLM4MOE

**iOS Impact:** ✅ Positive
- Expands Chinese language model support
- MoE architecture optimized for efficiency (good for mobile)

**Risk:** 🟢 Low
- Self-contained new model type
- No changes to existing models

---

### 3. Model Loading Performance Optimization
**Commit:** `27a2f21` - Optimize model loading performance (#34)

**Changes:**
- Parallelized loading of weights, tokenizer, and processor config
- Added model loading benchmarks (112 lines in Tests/Benchmarks/)
- Improved error handling
- Loading now happens concurrently instead of sequentially

**iOS Impact:** ✅ **Highly Positive**
- Significantly faster model initialization on iOS
- Reduced UI blocking during model loading
- Better resource utilization on multi-core iOS devices

**Risk:** 🟢 Low
- Well-tested with new benchmarks
- Error handling improved
- No breaking API changes

---

### 4. Chat Re-Hydration Support
**Commit:** `9c20e79` - Fix #44 Add support for chat re-hydration (#45)

**Changes:**
- Added 54 lines to ChatSession.swift
- New test cases in ChatSessionTests.swift (21 lines)
- Enables saving and restoring chat state

**iOS Impact:** ✅ Positive
- Allows persisting conversation state across app restarts
- Important for iOS app lifecycle (background/foreground transitions)

**Risk:** 🟢 Low
- New feature with dedicated tests
- No impact on existing chat functionality

---

### 5. External Tool Call Parser Support
**Commits:** `5225f29`, `10ec284`

**Changes:**
- Added toolcallStartTag and toolcallEndTag parameters to evaluation
- Enhanced ToolCallProcessor (84 line changes)
- Supports custom tool call formats beyond standard JSON

**iOS Impact:** ✅ Positive
- More flexible tool integration for your local tools
- Better compatibility with various LLM tool-calling formats

**Risk:** 🟡 Medium
- Changes core evaluation logic (38 line changes in Evaluate.swift)
- May affect existing tool call parsing if you use custom formats

---

## 🐛 Critical Bug Fixes

### 1. Mistral3 Configuration Parsing Fix
**Commit:** `5064b8c` - Fix Mistral3TextConfiguration parsing (#43)

**Problem:**
Loading certain Mistral 3 models (e.g., mlx-community/Ministral-3-8B-Instruct-2512-4bit) crashed with:
```
Unable to set lm_head on Mistral3TextModel: none not compatible with [biases: [131072, 64], scales: [131072, 64]]
```

**Root Cause:**
- VLM-style configs had `tie_word_embeddings: false` at top level, not in `text_config`
- Parser only checked `text_config`, defaulted to `true`
- Missing lmHead module caused crash when loading quantized weights

**Fix:**
- Now checks both top-level and text_config for tie_word_embeddings
- Changed default from `true` → `false` (safer for quantized models)

**iOS Impact:** ✅ **Critical Fix**
- Prevents crashes when loading popular 4-bit Mistral models
- Essential for iOS memory-constrained environments (4-bit quantization)

**Risk:** 🟢 Low
- Well-documented fix with clear rationale
- Backwards compatible (still checks text_config first)

---

### 2. GPTOSS Sliding Window Mask Fix
**Commit:** `ddc0e73` - Fix GPTOSS Fatal error in getSlidingWindowMask (#39)

**Problem:**
Fatal crash: `[broadcast_shapes] Shapes (1,64,512,641) and (1,64,512,640) cannot be broadcast`

**Root Cause:**
Off-by-one error in mask size calculation during prefill (L > 1):
- Mask had L + min(windowSize + 1, offset) columns (1025)
- KV cache had maxSize + L - 1 entries (1024)

**Fix:**
Corrected mask calculation to match actual cache size after trimming

**iOS Impact:** ✅ Critical Fix
- Prevents crashes when using GPTOSS models (e.g., GPTOSS 20B)
- Important for long-context scenarios on iOS

**Risk:** 🟢 Low
- Tested with GPTOSS 20B
- Mathematical fix with clear documentation

---

### 3. Gemma 3n Configuration Fixes
**Commit:** `5d89cc9` - fix(gemma3n): support per-layer intermediate_size array (#46)

**Problems Fixed:**
1. HuggingFace Gemma 3n models use array for intermediate_size (one per layer)
2. Missing `query_pre_attn_scalar` field in some configs
3. Sanitize function discarding non-language-model weights

**Fixes:**
- Introduced IntOrArray type for flexible config parsing
- Made query_pre_attn_scalar optional
- Preserved all weights in sanitize function

**Affected Models:**
- mlx-community/gemma-3n-E2B-it-4bit
- mlx-community/gemma-3n-E4B-it-4bit

**iOS Impact:** ✅ Positive
- Enables latest Gemma 3n models (efficient 4-bit versions)
- Important for iOS memory constraints

**Risk:** 🟢 Low
- Backwards compatible (IntOrArray handles both formats)
- Specific to Gemma 3n model family

---

## 🔧 Architecture Improvements

### 1. Expose Inner Model for All Models
**Commit:** `abfcad7` - Expose inner model for all models (#32)

**Changes:**
- All model classes now expose their inner model property
- Enables direct access to model internals for advanced use cases

**iOS Impact:** ⚠️ Neutral
- No functional change for standard usage
- Useful for debugging or custom model modifications

**Risk:** 🟡 Medium
- API surface expansion (could create coupling if misused)
- No breaking changes to existing code

---

### 2. Updated swift-transformers Dependency
**Commit:** `bb050e8` - Update swift-transformers version requirement (#28)

**Changes:**
- Package.swift updated with new version constraint

**iOS Impact:** ⚠️ Requires Verification
- Dependency version bump may include breaking changes
- Need to verify swift-transformers changelog

**Risk:** 🟡 Medium
- Dependency updates can introduce unexpected issues
- Should test thoroughly with your existing models

---

## 📊 Impact Summary

### Files Changed
- **61 files modified**
- **10,398 insertions, 559 deletions**
- **Major new files:**
  - GLM4MOE.swift (453 lines)
  - Mistral3.swift (1,109 lines)
  - Pixtral.swift (1,137 lines)
  - ModelLoadingBenchmarks.swift (112 lines)

### Components Affected
1. **Model Loading** - Performance optimizations, parallel loading
2. **Configuration Parsing** - Fixed Mistral3, Gemma3n issues
3. **VLM Support** - Complete Ministral 3/Pixtral implementation
4. **Tool Processing** - External parser support
5. **Chat System** - Re-hydration support
6. **Model Registry** - New model types (GLM4MOE, Mistral3)

---

## ⚠️ Risk Assessment

### 🔴 High Risk Areas: **None**

### 🟡 Medium Risk Areas:

1. **swift-transformers Dependency Update**
   - **Probability:** Medium
   - **Impact:** Could affect tokenizer behavior
   - **Mitigation:** Test with existing models, review swift-transformers changelog
   - **Action Required:** ✅ Test model loading and tokenization

2. **Vision-Language Model Integration**
   - **Probability:** Low-Medium
   - **Impact:** Large new codebase may have edge cases
   - **Mitigation:** Well-tested upstream, isolated to VLM models
   - **Action Required:** ⚠️ Test if you plan to use Pixtral models

3. **Tool Call Parser Changes**
   - **Probability:** Low
   - **Impact:** May affect custom tool call formats
   - **Mitigation:** Backwards compatible, only affects advanced usage
   - **Action Required:** ⚠️ Test if you use custom tool formats

4. **Exposed Inner Models**
   - **Probability:** Very Low
   - **Impact:** API expansion without breaking changes
   - **Mitigation:** Opt-in feature, no forced usage
   - **Action Required:** ℹ️ No action needed

### 🟢 Low Risk Areas:

1. **Performance Optimizations** - Well-tested with benchmarks
2. **Bug Fixes** - All fixes address specific crashes with clear reproduction
3. **New Model Types** - Self-contained, no impact on existing models
4. **Chat Re-Hydration** - New feature with dedicated tests

---

## ✅ Recommended Actions

### Before Upgrading

1. **Review swift-transformers changes**
   ```bash
   cd thirdparty/swift-transformers
   git log <old-version>..<new-version>
   ```

2. **Backup current working models**
   - Export current model configurations
   - Note which models are currently working

3. **Test plan preparation**
   - List all model types you currently use
   - Identify any custom tool call formats
   - Check if you rely on tie_word_embeddings behavior

### After Upgrading

1. **Test existing models** (Priority: High)
   - Load each model type you use
   - Verify tokenization works correctly
   - Test chat generation end-to-end

2. **Test quantized models** (Priority: High)
   - Especially 4-bit Mistral and Gemma models
   - Verify lm_head loading works

3. **Test tool calling** (Priority: Medium)
   - If you use tool calls, verify parsing still works
   - Test both standard and any custom formats

4. **Performance validation** (Priority: Low)
   - Measure model loading time (should be faster)
   - Check memory usage patterns

5. **Optional: Test new features**
   - Chat re-hydration (if needed)
   - VLM models (if interested in Pixtral)
   - GLM4MOE (if using Chinese models)

### Rollback Plan

If issues arise:
```bash
cd thirdparty/mlx-swift-lm
git checkout tag-20251226
# Rebuild your project
```

---

## 📝 Integration Notes for Your iOS App

### AIChatModelMLX Integration

Your `AIChatModelMLX` class should benefit from:

1. **Faster Loading** - Parallel weight/tokenizer loading
2. **Better Error Messages** - Improved error handling in loading
3. **Tool Call Flexibility** - Can now pass custom toolcallStartTag/toolcallEndTag if needed

### Model Configuration

Update `helper/models_*.json` if adding:
- Ministral 3 with vision models
- GLM 4.7 MOE models
- Gemma 3n models

### Memory Considerations

The new VLM support adds vision processing capabilities:
- Pixtral models are larger (vision encoder + language model)
- Test memory usage on target iOS devices
- May need to adjust context size limits for VLM models

### Testing Priority for Your App

| Priority | Test Case | Expected Outcome |
|----------|-----------|------------------|
| 🔴 Critical | Load existing MLX models | Same behavior, faster loading |
| 🔴 Critical | 4-bit quantized models (Mistral, Gemma) | No crashes, correct inference |
| 🟡 High | Tool calling with your local tools | Same behavior |
| 🟡 High | Model switching in UI | No crashes, state preserved |
| 🟢 Medium | Long-context chat | GPTOSS fix prevents crashes |
| 🟢 Medium | Chat persistence across app restarts | Re-hydration works |

---

## 🎯 Conclusion

**Upgrade Recommendation:** ✅ **Proceed with Upgrade**

**Rationale:**
- Critical bug fixes outweigh risks (Mistral3, GPTOSS, Gemma3n crashes)
- Performance improvements directly benefit iOS UX
- New features are opt-in and well-isolated
- Risk is manageable with proper testing

**Timeline Suggestion:**
1. **Week 1:** Test in development/audit environment
2. **Week 2:** Beta test with subset of models
3. **Week 3:** Full rollout if no issues found

**Success Criteria:**
- [ ] All existing models load without crashes
- [ ] Model loading time reduced by >30%
- [ ] No regressions in tool calling
- [ ] 4-bit models work on iOS devices with <4GB RAM

---

## 📚 References

- [GLM 4.7 Model Card](https://huggingface.co/THUDM/glm-4-9b)
- [Ministral 3 Release](https://mistral.ai/news/ministral-3b/)
- [Gemma 3 Family](https://blog.google/technology/developers/google-gemma-3/)
- [mlx-swift-lm Repository](https://github.com/ml-explore/mlx-swift-lm)

---

**Generated:** 2026-01-11
**Prepared for:** AIAssistant iOS App
**Next Review:** After testing phase completion
