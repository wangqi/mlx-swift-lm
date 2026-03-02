# MLX-Swift-LM Update: tag-20260224 → tag-20260302

**Update Date:** March 2, 2026
**Previous Version:** tag-20260224
**Current Version:** tag-20260302
**New Commits (upstream):** 4 commits (3 functional + 1 merge)

---

## Executive Summary

This is a **low-risk maintenance update** with two targeted bug fixes, one new model family (Qwen3.5 / Qwen3.5 MoE), and a minor API enhancement for wired memory. No breaking changes, no architecture refactoring.

### Risk Assessment: **LOW** (1/5)

| Risk Area | Level | Reason |
|-----------|-------|--------|
| KVCache serialization fix | **LOW** | Correctness fix; restores Python cross-platform compatibility |
| LFM2 nested RoPE params fix | **LOW** | Load-time fix for specific LFM2 variants |
| Qwen3.5 / Qwen3.5 MoE models | **LOW** | Additive only; no impact on existing models |
| `wiredMemoryTicket` on `generateTokens` | **LOW** | Optional parameter, default `nil`; existing code unchanged |
| API breaking changes | **NONE** | No public API modifications |

---

## Commits Included

| Commit | Author | Date | Description |
|--------|--------|------|-------------|
| `84213e5` | Ronald Mannak | 2026-02-27 | Add wiredMemoryTicket to GenerateTokens (#117) |
| `72e929a` | John Mai | 2026-02-28 | Add Qwen3.5 and Qwen3.5 MoE (#97) |
| `b08c1b2` | Adrien Grondin | 2026-02-27 | Allow reading LFM2 models nested rope params (#122) |
| `11968af` | Ivan Petrukha | 2026-02-27 | Fix KVCache serialization (#121) |

---

## Change Details

### 1. KVCache Serialization Fix (#121)

**Files:** `Libraries/MLXLMCommon/KVCache.swift`, `Tests/MLXLMTests/KVCacheTests.swift`

- **Root cause**: `BaseKVCache.metaState` getter returned `[]` (Swift empty array) but Python's base class returns `[""]` (array with one empty string). This caused Python ↔ Swift cross-platform serialization to mismatch when saving/loading prompt caches.
- **Fix 1**: `BaseKVCache.metaState` getter now returns `[""]` to match Python behavior.
- **Fix 2**: `ChunkedKVCache` type check in `savePromptCache()` moved before `KVCacheSimple` in the `switch` statement — required because `ChunkedKVCache` inherits from `KVCacheSimple`, so the subclass must be matched first.
- **Fix 3**: Removed redundant `KVCacheSimple.metaState` override (now handled by base class correctly).
- **Fix 4**: Loaded metadata made non-optional for cleaner API.
- **New tests**: `KVCacheTests.swift` gains serialization round-trip tests.

**iOS Device Impact:**
- Fixes potential prompt cache corruption when saving/restoring KV caches across sessions (prompt caching feature)
- No impact if prompt caching is not used

**Risk Level: LOW** — pure correctness fix, no behavioral change for uncached generation

---

### 2. LFM2 / LFM2 MoE Nested RoPE Params Fix (#122)

**Files:** `Libraries/MLXLLM/Models/LFM2.swift`, `Libraries/MLXLLM/Models/LFM2MoE.swift`

- **What changed**: Both `LFM2` and `LFM2MoE` models can now read RoPE (Rotary Position Embedding) parameters from nested config structures in addition to the flat layout.
- **Why**: Some published LFM2 model variants ship `rope_theta` and related values nested inside a sub-object rather than at the top level. The parser previously silently ignored them, leading to incorrect positional encoding and degraded output quality.

**iOS Device Impact:**
- Fixes loading errors / poor output quality for affected LFM2 model variants
- Existing correctly-formatted LFM2 models are unaffected

**Risk Level: LOW** — load-time config parsing fix only

---

### 3. Qwen3.5 and Qwen3.5 MoE Model Support (#97)

**Files Added:**
- `Libraries/MLXLLM/Models/Qwen35.swift` (+683 lines) — full Qwen3.5 text model
- `Libraries/MLXLLM/Models/Qwen35MoE.swift` (+75 lines) — Qwen3.5 Mixture-of-Experts variant
- `Libraries/MLXLLM/Models/Qwen3Next.swift` — minor update (+10/-6)
- `Libraries/MLXLLM/LLMModelFactory.swift` — registered both new model types

**Architecture Notes (Qwen3.5):**
- Separate `Qwen35Configuration` / `Qwen35TextConfiguration` codable structs
- Architecture type strings: `"qwen3_5"` and `"qwen3_5_moe"`
- MoE variant reuses the `Qwen35Configuration` config with sparse expert routing

**iOS Device Impact:**
- Qwen3.5 and Qwen3.5 MoE models can now be loaded and run via the MLX inference engine
- Smaller Qwen3.5 variants (0.6B, 1.7B, 4B) are well-suited for iPhone 15 Pro and above

**Risk Level: LOW** — additive only; zero impact on existing models

---

### 4. wiredMemoryTicket Added to generateTokens (#117)

**Files:** `Libraries/MLXLMCommon/Evaluate.swift`

- **What changed**: Both `generateTokens()` and `generateTokensTask()` gain a new optional parameter:
  ```swift
  wiredMemoryTicket: WiredMemoryTicket? = nil
  ```
- **Why**: The wired memory control system (introduced in tag-20260127) already supported the high-level `generate()` function. This change brings the same wired memory policy coordination to the lower-level raw token streaming API, enabling consistent memory management across both code paths.
- **Supported platforms**: macOS 15 / iOS 18 / tvOS 18 or newer (GPU devices with wired memory control). Falls back gracefully on older systems or when `nil` (default).

**iOS Device Impact:**
- Enables smoother, pause-free generation for callers using the raw token streaming API
- Only beneficial when a `WiredMemoryTicket` from an active policy is passed
- Default behavior (`nil`) is identical to before — no change required

**Risk Level: LOW** — opt-in parameter, default `nil`, no behavioral change for existing callers

---

## Files Changed Summary

| File | Change Type | Lines |
|------|-------------|-------|
| `Libraries/MLXLMCommon/KVCache.swift` | Bug fix | -19 / +13 |
| `Tests/MLXLMTests/KVCacheTests.swift` | New tests | +45 |
| `Libraries/MLXLLM/Models/LFM2.swift` | Bug fix | +7 / -1 |
| `Libraries/MLXLLM/Models/LFM2MoE.swift` | Bug fix | +7 / -1 |
| `Libraries/MLXLLM/Models/Qwen35.swift` | New model | +683 |
| `Libraries/MLXLLM/Models/Qwen35MoE.swift` | New model | +75 |
| `Libraries/MLXLLM/Models/Qwen3Next.swift` | Minor update | +10 / -6 |
| `Libraries/MLXLLM/LLMModelFactory.swift` | Registration | +2 |
| `Libraries/MLXLMCommon/Evaluate.swift` | Enhancement | +32 / -4 |

**Total**: 9 files changed, ~875 insertions, ~32 deletions

---

## iOS Device Impact Summary

| Change | iOS Benefit | Action Required |
|--------|-------------|-----------------|
| KVCache serialization fix | Prompt cache save/load now correct | None |
| LFM2 nested RoPE fix | LFM2 variants load without errors | None |
| Qwen3.5 support | New small/medium models available | Add to models.json if desired |
| wiredMemoryTicket on generateTokens | Memory-stable raw token streaming | None (opt-in) |

---

## Our Integration — Action Items

### Required: **NONE**

This is a drop-in replacement. No code changes required in AIAssistant.

### Optional — Qwen3.5 Models

If desired, add Qwen3.5 model entries to `helper/models_*.json`:
- Architecture type: `"qwen3_5"` or `"qwen3_5_moe"`
- Inference: `"mlx"` (MLX-Swift engine)
- Recommended small variants: 0.6B, 1.7B (good for iPhone)

---

## Testing Checklist

- [ ] Project builds successfully with updated submodule
- [ ] MLX model text generation works (basic chat)
- [ ] (Optional) Load an LFM2 model variant — verify clean load
- [ ] (Optional) Qwen3.5 model chat if model file is available
- [ ] No runtime warnings or crashes

---

## Overall Risk Rating

**LOW — safe to upgrade**

Three of four changes are pure correctness fixes or additive model support. The `generateTokens` API addition is strictly backward-compatible (new optional parameter, default `nil`). No architecture changes, no import renames, no behavioral regressions.

---

**Generated:** 2026-03-02
**Covers commits:** 3 upstream functional commits (tag-20260224 → tag-20260302)

