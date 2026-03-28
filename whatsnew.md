# mlx-swift-lm Upgrade Notes: tag-20260321 → tag-20260328

## Summary

This upgrade includes significant performance improvements, new KV cache persistence APIs, bug fixes for multi-tool-call agentic workflows, and embedding model improvements. Overall risk is **moderate**: mostly additive API changes with one dependency version bump.

---

## Changes

### Performance (High Impact for iOS)

**`perf: eliminate CPU←GPU sync in penalty processors, optimize TopPSampler (#147)`**

- **+35–65% faster token generation** on Apple Silicon by removing CPU←GPU synchronization in the hot path.
- All three penalty processors (`RepetitionContext`, `PresencePenaltyContext`, `FrequencyPenaltyContext`) previously called `token.item(Int.self)` on every generated token, forcing a GPU stall that blocked `asyncEval()` pipelining.
- Fix: replaced Swift `[Int]` token buffers with GPU-resident MLXArray ring buffers using `MLX.where` mask operations — no `.item()` or `.asArray()` calls remain in the hot path.
- Benchmark on Qwen3.5-4B (248K vocab, topK=20, presencePenalty=1.5): peak **70 → 95 tok/s (+35%)**, aggregate across 14 scenarios **34.6 → 57.2 tok/s (+65%)**.
- `TopPSampler` also optimized: uses `argPartition` O(V) to find top-K candidates instead of `argSort` O(V log V) on full vocabulary, then sorts only K candidates O(K log K).
- Sampling pipeline now mirrors Python `mlx-lm` order: `top_p → min_p → top_k`.

### KV Cache Persistence (New API)

**`Add KV cache initializers and cache access to ChatSession (#151)`**

New prefix-caching API enables building a `KVCache` from a long shared context (system prompt + document) once, saving to disk, and restoring across sessions to skip re-prefilling the same tokens.

New `ChatSession` APIs:
```swift
// Initialize with a pre-built cache
ChatSession(_ model: ModelContainer, cache: [KVCache], ...)
ChatSession(_ model: ModelContext, cache: [KVCache], ...)

// Read the live cache after generation
func currentCache() async -> [KVCache]?

// Save the live cache to disk (.safetensors)
func saveCache(to url: URL) async throws
```

**`Add copy() to KVCache protocol and all implementations (#158)`**

- New `copy()` method on `KVCache` protocol enables deep-copying a prefix cache to reuse across multiple `ChatSession` instances without reloading from disk.
- Implemented for: `KVCacheSimple`, `RotatingKVCache`, `QuantizedKVCache`, `ChunkedKVCache`, `ArraysCache`, `MambaCache`, `CacheList`.
- **mlx-swift dependency bumped to 0.31.1** — picks up fix for `array[.ellipsis]` returning `self` instead of a copy.

### Bug Fixes

**`Handle multiple tool calls in ChatSession (#162)`**

- Fixes #134: the generation loop was breaking on the first tool call, canceling the stream, and losing subsequent tool calls.
- Now drains the full stream, collects all pending tool calls into `[ToolCall]`, dispatches them all, then restarts with all tool results. Skips dispatch if `Task.isCancelled`.
- Critical fix for agentic workflows that issue parallel tool calls in a single model turn.

**`add missing context/toolcall parameters (#140)`**

- Fixes missing `context` and tool call parameters in certain code paths (see #139).

**`fix unreliable tests (#128)`**

- Random weight model and tokenizer made deterministic in tests; fixes flaky test failures (#119).

### Embedding Model Improvements

**`Add model-defined pooling fallback for embedding models (#156)`**

- Adds a model-defined pooling fallback for embedding models.
- Uses `takeAlong` for last-token pooling (avoids shape issues from `take`).

---

## iOS-Specific Impact

| Change | Impact |
|--------|--------|
| GPU sync elimination in penalty processors | Direct speed improvement on all Apple Silicon devices |
| TopPSampler argPartition optimization | Reduces CPU/GPU work for large vocabulary models |
| KV cache persistence API | Enables faster session restore for document-heavy use cases |
| Multiple tool call fix | Required for reliable agentic/tool-use workflows |
| mlx-swift bumped to 0.31.1 | Package dependency update — requires testing |

---

## Risk Assessment

**Overall Risk: MODERATE**

| Area | Risk | Reason |
|------|------|--------|
| `KVCache` protocol + `copy()` | Low-Medium | Additive protocol requirement; only custom `KVCache` implementations outside the library would break |
| `ChatSession` new initializers | Low | Additive API; existing call sites unaffected |
| Penalty processor rewrite | Low-Medium | Significant algorithmic change in hot path; output distribution should be equivalent but sampling behavior could differ subtly in edge cases |
| `TopPSampler` refactor | Low | Mirrors Python reference implementation; output should be equivalent |
| mlx-swift 0.31.1 bump | Medium | Transitive dependency update; verify no conflicts with other mlx-swift consumers in the project |
| Multi-tool-call fix | Low | Pure bug fix; only improves correctness |

**Recommended:** Run existing generation and tool-use tests before shipping. Verify mlx-swift 0.31.1 resolves without conflicts in `Package.resolved`.
