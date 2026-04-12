# mlx-swift-lm Upgrade Notes: tag-20260403 → tag-20260412

## Summary

Four functional commits (7 PRs total) bringing speculative decoding for faster generation, a rebuilt Llama 3 tool-call pipeline with parallel call support, a critical Swift 6 Sendable fix for Release iOS builds, and a Pythonic tool-call parser rewrite using modern Swift Regex. No new model architectures. Our custom crash-guard patches (`QuantizationBitsError`, `ModelLoadError`) were preserved through the merge.

Overall risk is **LOW**: no breaking API changes, all additions are opt-in or fix existing bugs.

---

## Changes

### 1. Speculative Decoding (#173)

- New `SpeculativeTokenIterator` in `Evaluate.swift` implements the speculative decoding loop: a lightweight draft model proposes `numDraftTokens` (default: 2) tokens per round, which the main model verifies in a single batch pass. Accepted tokens are kept; rejected tokens cause the main model to regenerate from the rejection point.
- New `generate()` overload added (our conflict resolution preserved it alongside the existing overloads):
  ```swift
  public func generate(
      input: LMInput,
      cache: [KVCache]? = nil,
      parameters: GenerateParameters,
      context: ModelContext,
      draftModel: any LanguageModel,
      draftCache: [KVCache]? = nil,
      numDraftTokens: Int = 2,
      wiredMemoryTicket: WiredMemoryTicket? = nil
  ) throws -> AsyncStream<Generation>
  ```
- 84-line `SpeculativeDecodingTests.swift` added to verify correctness.
- **iOS impact**: Requires two models in memory simultaneously — violates the app's mutual-exclusion memory policy (`willLoadTextModel()`). Feature is entirely opt-in; existing `generate()` calls are unaffected. Do not expose to users without first validating available RAM via `canLoadModel(fileSizeMB:)`.

---

### 2. Llama 3 Tool Calling Rebuilt (#145)

Llama 3 models emit tool calls in two different formats depending on model size and prompt: a JSON array `[{"name":...,"parameters":...}]` or a Pythonic array `[func1(), func2()]`. The previous implementation handled neither format correctly for parallel calls.

- **New `Llama3ToolCallParser.swift`**: Parses both the `parameters` and `arguments` key variants in the JSON array, extracting multiple parallel tool calls in a single `parseEOS` pass.
- **`ToolCallProcessor`**: `startTag` is now `<|python_tag|>`, ensuring the processor correctly buffers all tool output without leaking raw tags into the streaming UI.
- **`ToolCallFormat`**: Extended with Llama 3 format detection, wired into `LLMModelFactory` for automatic selection.
- **`PythonicToolCallParser`**: Refactored from `NSRegularExpression` to Swift 5.7+ `Regex` literals. Now extracts multiple sequential calls `[func1(), func2()]` via `parseEOS`.
- Integration unit tests added covering both parsers.
- **iOS impact**: Low risk. `NSRegularExpression` → Swift `Regex` requires iOS 16+; app targets iOS 18.6+. Llama 3 tool calls that previously produced garbled output or missed parallel calls will now work correctly.

---

### 3. Preserve JSONValue in Llama3ToolCallParser — Swift 6 Sendable Fix (#203)

`Llama3ToolCallParser` was converting decoded `[String: JSONValue]` arguments through `Any` (via `.anyValue`) when constructing `ToolCall.Function`. This intermediate `Any` conversion violated Swift 6 `Sendable` rules, causing compilation failure in Release builds targeting iOS.

- **Fix**: New `ToolCall.Function.init(name:arguments:[String:JSONValue])` overload added. The parser passes `JSONValue` directly, eliminating the `Any` round-trip.
- **iOS impact**: **Critical.** Without this fix, any app using `Llama3ToolCallParser` fails to compile in Release mode under Swift 6. Merged as a standalone patch immediately after the Llama 3 tool-call commit.

---

### 4. IntegrationTesting Xcode Project (#142)

- New `IntegrationTesting/IntegrationTesting.xcodeproj` with end-to-end tool-call tests for Mistral 3, Nemotron, and Qwen3.5.
- Requires macOS with Metal; downloads models from HuggingFace Hub on first run.
- `IntegrationTestHelpers` library expanded with 395 lines of model-specific helpers.
- **iOS impact**: None — macOS-only test infrastructure.

---

### 5. Doc Comments and CI Verification (#176)

- Doc comments corrected across `Evaluate.swift`, `ChatSession.swift`, `LoRA+Layers.swift`, `ModelFactory.swift`, `UserInput.swift`, and others.
- New `scripts/verify-docs.sh` runs in CI to catch doc regressions.
- **iOS impact**: None. No logic changes.

---

### 6. README Updates (#201, #204)

- Anchor links fixed; integration documentation expanded.
- **iOS impact**: None.

---

## iOS-Specific Impact

| Change | Impact |
|--------|--------|
| Speculative decoding | Opt-in faster generation; requires two models in RAM simultaneously — use with care |
| Llama 3 tool calling rebuilt | Parallel tool calls now work correctly for Llama 3 models on device |
| Swift 6 Sendable fix | **Required** — fixes Release build failure for Llama 3 tool-call users |
| PythonicToolCallParser Regex rewrite | Multi-call Pythonic tool output correctly extracted; no NSRegularExpression overhead |
| ToolCallProcessor startTag fix | Streaming UI no longer leaks raw `<|python_tag|>` tokens |

---

## Risk Assessment

**Overall Risk: LOW**

| Area | Risk | Reason |
|------|------|--------|
| Speculative decoding | Medium | Two-model RAM requirement; must remain opt-in on iOS |
| Llama 3 tool call refactor | Low | Additive new parser; existing JSON/Pythonic paths preserved |
| PythonicToolCallParser Regex rewrite | Low-Medium | Semantics equivalent; new integration tests provide confidence; Swift Regex edge cases possible on unusual inputs |
| JSONValue Sendable fix | Low | Fixes compiler error; runtime behavior identical or better (no lossy Any conversion) |
| ModelFactory / UserInput doc changes | Minimal | Doc and formatting only; no logic touched |
| Our custom patches | No risk | `QuantizationBitsError` and `ModelLoadError` preserved through merge conflict resolution |

---

## Our Custom Patches (preserved across merge)

- `fallbackToolCallParser` parameter on `generate()` — bridges app-level parsers into the generate pipeline (wangqi modified 2026-03-10)
- `QuantizationBitsError` — prevents fatal crash on unsupported quantization bit depths (e.g. 7-bit)
- `ModelLoadError.directoryNotAccessible` — prevents crash when model directory is missing or deleted at load time

---

## Previous: tag-20260328 → tag-20260403

Swift 6 strict concurrency, 10x–15x model-load speedup via swift-tokenizers, HuggingFace Hub decoupled to optional module, RoPE unified across 45 models.
