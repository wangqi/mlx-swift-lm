# MLX-Swift-LM Upgrade Notes

**Upgrade Range:** `tag-20251112` to `tag-20251226`

**Total Changes:** 78 files, +3,262 / -924 lines

---

## Summary

This upgrade includes significant improvements to Swift concurrency safety, new model support, cache optimizations aligned with Python mlx-lm, and several bug fixes. The changes are particularly beneficial for iOS applications due to better thread safety and memory management.

---

## New Features

### 1. New Model Support

| Model | Description | File Added |
|-------|-------------|------------|
| **Mistral 3** | Latest Mistral model with Llama4-style attention scaling | `Mistral3Text.swift` (502 lines) |
| **Jamba 3B** | Hybrid Mamba-Transformer architecture | `Jamba.swift` (581 lines) |
| **Olmo 3** | Allen AI's Open Language Model v3 | `Olmo3.swift` (343 lines) |
| **AfMoE** | Arcee-AI's Mixture of Experts architecture | `AfMoE.swift` (601 lines) |

### 2. New ChatSession API

A new `ChatSession` class (`ChatSession.swift`, 246 lines) provides a simplified API for multi-turn conversations:

```swift
let modelContainer = try await loadModelContainer(id: "mlx-community/Qwen3-4B-4bit")
let session = ChatSession(modelContainer)
print(try await session.respond(to: "What are two things to see in San Francisco?"))
print(try await session.respond(to: "How about a great place to eat?"))
```

**Key benefits:**
- Automatic KV cache management across turns
- System instruction support
- Image/video processing for VLMs
- Thread-safe design using ModelContainer's actor isolation

### 3. Enhanced RoPE Support

New RoPE (Rotary Position Embedding) implementations:
- **Llama3RoPE**: Frequency-scaled RoPE for Llama 3 models
- **initializeRope() factory**: Unified RoPE initialization supporting `default`, `linear`, `llama3`, `yarn`, and `longrope` types
- **SuScaledRoPE**: Renamed from `SuScaledRotaryEmbedding` with improved implementation

---

## Improvements

### 1. Swift Concurrency & Thread Safety (Major)

**Critical improvements for iOS stability:**

| Change | Impact |
|--------|--------|
| `ModelContainer.perform()` now uses `sending` keyword | Enables safe transfer of non-Sendable types like `LMInput` across isolation boundaries |
| New thread-safe convenience methods on ModelContainer | `prepare()`, `generate()`, `decode()`, `encode()`, `applyChatTemplate()` |
| Deprecated non-thread-safe methods | Clear migration path with deprecation warnings |
| Registry classes now properly isolated | Resolved concurrency warnings in `ModelTypeRegistry` and `ProcessorTypeRegistry` |
| Tool handler made `Sendable` | Fixed concurrency warnings in tool system |
| `[String: Any]` replaced with `[String: any Sendable]` | Type-safe sendable dictionaries |

**New AsyncStream-based generation:**
```swift
// Old (deprecated)
let result = generate(input: lmInput, parameters: params, context: context) { tokens in
    .more
}

// New (recommended)
let stream = try generate(input: lmInput, parameters: params, context: context)
for await generation in stream {
    switch generation {
    case .chunk(let text): print(text)
    case .info(let info): print(info.tokensPerSecond)
    case .toolCall(let call): handleToolCall(call)
    }
}
```

### 2. KV Cache Optimizations (Aligned with Python mlx-lm)

**RotatingKVCache improvements:**
- Fixed sliding window mask calculation (`.<` instead of `.<=`)
- Optimized `makeMask()` with offset capping for better memory usage
- Proper single-token vs multi-token mask handling
- Cache growth allowance during prompt prefill (`maxCacheSize + S - 1`)

**New cache features:**
- `makeMask()` method added to `KVCache` protocol
- New `createAttentionMask(h:cache:windowSize:returnArray:)` with single cache support
- `CacheList.trim()` now trims all caches, not just the first

### 3. Prompt Time Metric Fix

- `TokenIterator` now correctly measures prompt prefill time separately
- `GenerateCompletionInfo.promptTime` includes actual prefill duration
- Summary output now shows prompt time: `Prompt: X tokens, Y tokens/s, Zs`

---

## Bug Fixes

| Issue | Fix |
|-------|-----|
| Prompt time metric not measured correctly | Added `promptPrefillTime` tracking in `TokenIterator` |
| SuScaledRoPE implementation issues | Renamed and fixed implementation |
| Sliding window mask off-by-one error | Changed `linds .<= rinds + windowSize` to `linds .< rinds + windowSize` |
| QuantizedKVCache unused validation | Removed unused validation code |
| Compiler warnings throughout codebase | Fixed ~50+ warnings |

---

## Breaking Changes

### Deprecations (Code Still Works)

1. **`SuScaledRotaryEmbedding`** - Renamed to `SuScaledRoPE`
2. **Callback-based `generate()` functions** - Use AsyncStream-based version instead
3. **`createAttentionMask(h:cache:[KVCache]?,returnArray:)`** - Use single cache version

### Potential Breaking Changes

1. **`LogitSampler` protocol** - Removed `Sendable` conformance requirement (may affect custom samplers)
2. **`GenerateResult`** - Removed `Sendable` conformance (internal type, unlikely to affect users)
3. **Tool schema types** - Now require `Sendable` conformance

---

## Risk Assessment

### Overall Risk: **LOW-MEDIUM**

| Category | Risk Level | Details |
|----------|------------|---------|
| **Compilation** | Low | May see deprecation warnings for old APIs |
| **Runtime Stability** | Low | Changes improve thread safety, reducing crashes |
| **Performance** | Low-Positive | Cache optimizations should improve memory usage |
| **API Compatibility** | Low-Medium | Deprecated APIs still work; new APIs available |
| **Model Compatibility** | Low | Existing models continue to work |

### Specific Risks

#### 1. Concurrency Changes (Low Risk)
- **Risk**: Code using old callback-based `generate()` will show deprecation warnings
- **Mitigation**: Warnings only; old code continues to work
- **Action**: Migrate to AsyncStream-based API at convenience

#### 2. KV Cache Behavior (Low Risk)
- **Risk**: Sliding window models may behave slightly differently due to mask fix
- **Mitigation**: Fix aligns with Python implementation (correct behavior)
- **Action**: Test sliding window models if used

#### 3. Tool System Sendable (Low Risk)
- **Risk**: Custom tools may need `Sendable` conformance
- **Mitigation**: Only affects custom tool implementations
- **Action**: Add `Sendable` to custom tool types if compilation fails

### iOS-Specific Considerations

| Aspect | Assessment |
|--------|------------|
| **Memory Safety** | Improved - better cache management |
| **Thread Safety** | Significantly improved - proper actor isolation |
| **Energy Efficiency** | Neutral to positive - cache optimizations |
| **Metal Performance** | Neutral - no Metal-specific changes |

---

## Recommended Actions

### Before Upgrading

1. Ensure all custom tools conform to `Sendable` if any
2. Note any use of callback-based `generate()` for future migration

### After Upgrading

1. Build and fix any deprecation warnings (optional but recommended)
2. Test sliding window models if used (Mistral, etc.)
3. Consider migrating to `ChatSession` for simpler conversation handling
4. Consider migrating to AsyncStream-based generation for better concurrency

### Testing Checklist

- [ ] Basic text generation works
- [ ] Multi-turn conversations work
- [ ] VLM (Vision-Language Models) work if used
- [ ] Tool calling works if used
- [ ] Memory usage is stable during long sessions
- [ ] No threading crashes under concurrent access

---

## Commit Summary

| Commit | Description |
|--------|-------------|
| `d9f46e3` | Fix many compiler warnings, add thread-safe APIs |
| `74f85d9` | Add Mistral 3, fix SuScaledRoPE |
| `051c3e1` | Add Arcee-AI's AfMoE |
| `b5db842` | Add Olmo 3 |
| `85b3dce` | Add Jamba 3B |
| `1e5e20e` | Align cache implementation with Python mlx-lm |
| `84db693` | Fix prompt time metric |

---

*Generated: 2025-12-26*
