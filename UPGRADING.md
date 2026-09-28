# MLX Stack — Versions & Upgrade Status

Records the current pinned state of the three self-managed MLX repos so a future upgrade knows exactly what it is
starting from. Update this file on every upgrade (it is part of the `mlx-swift-lm-upgrade` skill's deliverables).

**Last updated:** 2026-09-28

> These three are **independent local git repos** under `thirdparty/` (not app submodules). The app
> (`AIAssistant.xcodeproj`) wires them as local SwiftPM packages; a root-level `XCLocalSwiftPackageReference` for
> `thirdparty/mlx-swift` overrides the GitHub `mlx-swift` for **both** live consumers (`mlx-swift-lm` and
> `mlx-audio-swift`). After resolution, `Package.resolved` must contain **no** `ml-explore/mlx-swift` entry.

---

## Current state

| Repo | Remote (origin) | Branch | HEAD | Role |
|------|-----------------|--------|------|------|
| `thirdparty/mlx-swift-lm` | `wangqi/mlx-swift-lm` | `tag-20260928` | `2495a6f` | LLM/VLM layer (the package upgraded every 7-10 days) |
| `thirdparty/mlx-swift`    | `wangqi/mlx-swift`    | `prism-1bit-0.31.4` | `37b3ca1` | Swift API + vendored mlx-core; carries the PrismML patch |
| `thirdparty/mlx`          | `wangqi/mlx` (+ `prism` = `PrismML-Eng/mlx`) | `prism-1bit-0.31.1` | `48db7fe5` | mlx-core C++ fork; holds the PrismML 1-bit/2-bit patch |

### Engine version surfaced in the app
- `LocalModelEngineInfo.mlxSwiftInfo.version` = `"20260928"` (`views/settings/models/LocalModelAboutView.swift`).

---

## The two version axes (do not conflate)

`mlx-swift` carries two independent versions:

| Axis | Value | Where it lives |
|------|-------|----------------|
| **Swift-package version** (git tag / API surface) | **0.31.4** (`dc43e62`) + the #429 cherry-pick (`37b3ca1`) | the `mlx-swift` release commit our fork branch `prism-1bit-0.31.4` is based on. Upstream `mlx-swift-lm` now pins `.upToNextMinor(from: "0.31.6")` (#484, "*.4 was missing new API that the current code calls*") — **that API is #429**, `DType.greatestFiniteMagnitudeArray` + `MLXArray.maskFill`, which this fork already carries as the additive cherry-pick taken 2026-07-22. See "Why 0.31.6 does not force a move" below |
| **Vendored mlx-core (C++)** | **0.31.1** (`ce45c52`) | `thirdparty/mlx-swift/Source/Cmlx/mlx` submodule + `mlx/version.h` (`MLX_VERSION 0.31.1`); = PrismML's patch base |

A 0.31.1 core backs a 0.31.4 Swift API. Keep the **core at the PrismML base (0.31.1)** and base the **Swift sources
on the 0.31.4 release** unless upstream forces a move.

### Why the Swift sources are based on the 0.31.4 *release* (`dc43e62`), not `mlx-swift` `main`
`mlx-swift` `main` HEAD (`e23ae6b`) is past 0.31.4 and ships a CUDA build-tool plugin `Source/Encuda` that uses
`Foundation.Process` — `API_UNAVAILABLE` on iOS — which hard-fails the iOS build (`cannot find type 'Process'`).
The tagged 0.31.4 release has no `Encuda` target, so it is the safe base.

Upstream mlx-swift has since fixed exactly that (PR #437, "guard use of Process — does not build on iOS", `0bb916c`,
in 0.31.6), which corroborates the diagnosis above and removes the blocker for a *future* move. It is not a reason to
move now — see below.

### Why 0.31.6 does not force a move (audited 2026-08-31)
`mlx-swift-lm` PR #484 raised its requirement to `0.31.6` because the merged code calls `MLXArray.maskFill(for:)` and
the `DType.finfo` extensions (`KVCache.swift`, `ThinkingBudget.swift`). Those are **#429**, already on
`prism-1bit-0.31.4` at `37b3ca1`. Auditing the rest of `prism-1bit-0.31.4 → 0.31.6`, nothing else is reachable from
`mlx-swift-lm` or the app:

| Delta | Reachable from us? |
|---|---|
| #429 `MLXArray.maskFill` / `DType.finfo` | **yes — already cherry-picked** |
| #413 Linux + CUDA SPM support (`Source/Encuda`, `GPU+CUDA.swift`, `CudaBuild.json`, `cuda_jit_sources.h`, and all 347 lines of `MLXFastKernel.swift` churn) | no — the kernel file is only `#if`-split; the Apple-platform API surface is unchanged, and this fork has no `Source/Encuda` target at all |
| #437 "guard use of Process" | no — only touches `Source/Encuda`, which #413 introduced |
| #431 MultiOptimizer, #432 Muon, #433 LR schedules | no — training-only optimizers, no consumer in `mlx-swift-lm` or the app |
| #434 `.complex64` moved to the float32 `finfo` branch | no — complex64 unused |
| #422 `Device` default resolved from the C++ core instead of hard-coded `.gpu` | no — only changes CPU-only hosts (Linux without CUDA, no Metal); Apple + Metal resolves to GPU either way |

Verified by build rather than by reading alone: `swift build`, the iOS scheme and the macOS scheme all compile
against the local 0.31.4-based fork with upstream's 0.31.6-requiring sources.

---

## Fork-local patches in `mlx-swift-lm` (carry these across every upgrade)

Separate from the PrismML patch below, which lives in `mlx` / `mlx-swift`. Each block is marked in
place with `// wangqi modified YYYY-MM-DD`, so `git diff` against the upstream tag finds them.

> **No `MLXVLM/Models/*.swift` file is fork-patched any more (since 2026-08-31).** Qwen3VL and
> GlmOcr, the last two `chunkedVLMPrefill` holdouts, were retired when upstream PR #475 gave each of
> them its own windowed `prepareContinuation`. `Libraries/MLXLMCommon/ChunkedPrefill.swift` stays:
> `testcases/engines/local/MLXVLMLongPromptTests.swift` (macOS only) exercises its slicing math directly, and it is the escape
> hatch for the next model upstream leaves single-shot.

The rest of the fork surface is: `fallbackToolCallParser` threading (Evaluate → ToolCallFormat →
StandardTokenStreamDecoder → ToolCallProcessor), the `pendingOutput` invisible-start-tag buffer, the
Pythonic JSON fallback, `Gemma4FunctionParser`, `ModelLoadError.directoryNotAccessible`, the
`QuantizationBitsError` guard (see below — **it must keep admitting bits=1**), MLXLogCollector
tracing, and the two ChatSession changes below.

### `Libraries/MLXLMCommon/Load.swift` — `supportedBits` must include 1 (2026-09-17)

```swift
let supportedBits: Set<Int> = [1, 2, 3, 4, 5, 6, 8]
```

Added 2026-03-31 as `[2, 3, 4, 5, 6, 8]`, to stop the then-unpatched C++ layer from hard-crashing on
an unsupported width. It became wrong on 2026-06-22, when `thirdparty/mlx` (`prism-1bit-0.31.1`)
gained the PrismML patch and `affine_quantize` started accepting `bits=1` — the allow-list kept
rejecting a case the kernels handled, and because `QuantizationBitsError.errorDescription` reproduces
upstream's wording verbatim ("The supported bits are 2, 3, 4, 5, 6 and 8") the throw read as a
*kernel* failure for three months. Widened 2026-09-17; `Bonsai-4B-mlx-1bit` then loaded and generated
correctly at 50.4 tok/s decode.

**On upgrade:** if a merge restores the upstream-shaped list, or drops the guard and lets the C++
layer throw, 1-bit model loading breaks again with a message that blames the kernels.
`testcases/ai/BonsaiLowBitInferenceTests.testBinary4BInferenceCoherentAndBenchmarks` is the gate —
run it on macOS/Metal after any merge that touches `Load.swift`. Keep the guard (it is still correct
for widths a future base genuinely will not support); just keep `1` in the set.

### `Libraries/MLXLLM/Models/LFM2.swift` — `language_model.` prefix strip + `intermediate_size` alias (2026-09-28)

`mlx-community/LFM2.5-2.6B-4bit` (in the prod catalogue) declares `Lfm2ForCausalLM` / `model_type:
lfm2` but prefixes all 600 tensors `language_model.`, as a VLM-shaped conversion does. It has an empty
`vision_config` and no `preprocessor_config.json`, so the app routes it to `LLMModelFactory` →
`LFM2Model`, whose `sanitize` only transposed conv weights. Every load failed with `UpdateError:
Key model.embed_tokens.weight not found`, and `UpdateError` is not `unsupportedModelType`, so the
VLM fallback never ran. `sanitize` now drops a leading `language_model.` (anchored, so an unprefixed
checkpoint is untouched), matching what Qwen35 / Gemma4 already do. Sanitize runs before
`quantize(model:)` in `Load.swift`, so the `.scales` lookup sees the stripped names too.

The strip exposed a second defect: `UpdateError: Mismatched parameter
model.layers.0.feed_forward.w1.weight`. That `config.json` has only `intermediate_size` (10752), the
current Transformers key, and no legacy `block_ff_dim`, so `blockFFDim` fell back to `hiddenSize`
(2048). `LFM2Configuration.init(from:)` now reads `intermediate_size` (through a private
`AliasCodingKeys`, so the synthesized `encode(to:)` is unchanged) when `block_ff_dim` is absent.

**On upgrade:** if upstream rewrites `LFM2Model.sanitize` or `LFM2Configuration`, keep both. The gate is the MLX
regression suite's `LFM2.5-2.6B-4bit` row (`helper/scripts/model_regression/run_model_tests.py
--mlx-only --only LFM2.5-2.6B`).

### `Libraries/MLXLMCommon/ChatSession.swift` (2026-08-24)

Two changes that **must not be separated** — shipping the first without the second turns a silent
slowdown into an uncatchable process abort.

1. **The attention-mask veto accepts an all-ones mask.** `carriesAttentionMask` was
   `input.text.mask != nil`, and `Qwen3VL` / `Qwen3.5-VL` attach an all-ones `int8` mask
   unconditionally on their *text-only* branch (`Qwen3VL.swift:121-124`) — so prompt-cache reuse was
   vetoed on every turn for the entire family. Measured at 28.7k tokens: turns 2 and 3 cost 20.1s /
   22.0s against a forced full prefill of 20.3s. The mask is inert: those models pass `mask: nil` to
   their own language model on every branch, and `LMInput.Text.sequenceLengths` returns
   `tokens.dim(1)` for an all-ones mask, identical to the no-mask fallback. Only a **sparse** mask is
   a real exclusion. Widened to `int32` before summing so an `int8` accumulator cannot overflow.

   **This diverges from an upstream test, deliberately** (recorded 2026-08-31).
   `ChatSessionTests.testExactPrefixReuseRebuildsWhenPreparedInputHasMask` builds an all-ones mask
   and asserts a rebuild; the fork reuses, so the fork's copy is renamed
   `testExactPrefixReuseWithAnAllOnesMaskIsNotVetoed` and asserts the suffix is smaller than the
   rendered prompt. Expect this collision on every future merge. Upstream removed the mask from
   Qwen3-VL itself in PR #549, but **FastVLM, Pixtral, Idefics3, SmolVLM2, Mistral3, MuseGlimmer,
   GlmOcr, Gemma4 and PaliGemma still attach one**, so the relaxation remains load-bearing — do not
   "resolve" this by taking upstream's assertion.

2. **The reduced input preserves the rank `prepare` produced.** All three reuse branches built
   `LMInput(tokens: MLXArray(Array(promptTokenIds[...])))`, which is always 1-D because the ids came
   from `asArray(Int.self)`. Right for the text path; wrong for a VLM, whose `prepare` produces
   `[1, N]` and whose `getRopeIndex` opens with `inputIds.dim(1)` — `Fatal error: SmallVector out of
   range` (`mlx/c/array.cpp:335`), not a Swift error. The mask veto had been accidentally shielding
   every VLM from this. `preparedRank` is read **before** the switch, because the local function is
   assigned back into `input` and reading it inside would be a simultaneous access to the same `var`.

   Verified together by `IntegrationTesting/IntegrationTestingTests/KVCacheReuseProbeTests.swift`
   (`MLX_RUN_KVCACHE_PROBE=1`): `qwen3-vl-4b` goes from `rebuild` every turn to 0.361s / 0.263s
   against a 129.1s warm control, answers correct, no abort.

### `Libraries/MLXLMCommon/Evaluate.swift` (2026-08-24)

**`generateRecordingTokens`** — a public overload of `generate(input:cache:parameters:context:…)`
that also returns `Task<[Int], Never>` carrying the ids the model emitted. Purely additive: it is the
existing call plus the `RecordingGeneratedTokens` collector that `generateTaskRecordingTokens` (module-
internal, used by `ChatSession`) already used.

The app needs it because it holds a `[KVCache]` across calls and cannot use `ChatSession`. After
generation the cache represents prompt + generation, and on a hybrid topology
(`MambaCache.isTrimmable == false`) the generation cannot be trimmed back off — pure append is the
only strategy such a cache can execute, and appending requires knowing exactly what the cache holds.
Re-tokenizing the model's own text is not a substitute: it is not guaranteed to reproduce the ids it
emitted, and a wrong ledger is silent corruption. See `helper/docs/mlx-swift.md` § 3a.

### `IntegrationTesting/IntegrationTestingTests/KVCacheReuseProbeTests.swift` (new, 2026-08-24)

Opt-in (`MLX_RUN_KVCACHE_PROBE=1`), loads GBs of weights, never runs by accident. Four cases pinning
that **shape, not topology, decides whether a hybrid can reuse**: gemma-4 (dense) and Qwen3-VL
(dense + all-ones mask) reuse; Qwen3.5-2B reuses in the **agent** shape and does not in a plain chat.
`qwen3-vl-4b` loads from `MLX_QWEN3VL_DIR`, not a Hub id — `mlx-community/Qwen3-VL-4B-Instruct-4bit`
ships one `model.safetensors` alongside a stale index naming two shards.

> Running it: `-only-testing` needs the trailing `()` on a swift-testing id, or it matches nothing and
> **exits zero having run no tests**. The env var must reach the test runner, so use
> `TEST_RUNNER_MLX_RUN_KVCACHE_PROBE=1`, not a bare `MLX_RUN_KVCACHE_PROBE=1`.

---

## PrismML 1-bit/2-bit quantization patch

- **`thirdparty/mlx` branch `prism-1bit-0.31.1`** (off `ce45c52`): cherry-pick of `PrismML-Eng/mlx` `ce45c52..d90771c`
  (3 commits, quantization path only — `mlx/ops.cpp`, `mlx/primitives.cpp`, `backend/cpu/quantized.cpp`,
  `backend/metal/quantized.cpp`, `backend/metal/jit_kernels.cpp`, `backend/metal/kernels/quantized*.{h,metal}`,
  `quantized_nax*.{h,metal}`, python bindings/tests, benchmarks). See `thirdparty/mlx/PRISM-PATCH.md`.
- **`thirdparty/mlx-swift` branch `prism-1bit-0.31.4`** (off `dc43e62`, plus the additive #429 cherry-pick
  `37b3ca1` taken 2026-07-22): `Source/Cmlx/mlx` gitlink → `48db7fe5`;
  4 regenerated `Source/Cmlx/mlx-generated/` quantized files (`metal/quantized.h`, `metal/quantized_nax.h`,
  `quantized.cpp`, `quantized_nax.cpp`); `.gitmodules` url → `wangqi/mlx`; `Package.swift`
  `.define("FMT_CONSTEVAL", to: "")`.
- **`thirdparty/mlx-swift-lm/Package.swift`**: `mlx-swift` dependency switched to `.package(path: "../mlx-swift")`.
- **Regression guard:** the delta is additive + gated. bits≥2 host quantize, GPU quantize kernel, and matmul paths
  are unchanged (only `if(bits==1)` branches inserted ahead of them). Proven by
  `thirdparty/mlx-swift/Tests/MLXTests/QuantizationTests.swift` — `testBitExactRegression` (2/4/8-bit) and
  `testLowBitReconstruction` (bits=1 binary round-trip; bits=1/2 matmul consistency).

---

## Consumers (regression scope)

| Consumer | Depends on `mlx-swift`? | Notes |
|----------|-------------------------|-------|
| `thirdparty/mlx-swift-lm` | yes (local path dep) | the package this file lives in |
| `thirdparty/mlx-audio-swift` | yes — `MLX`, `MLXNN`, `MLXFast` | pins `.upToNextMajor(from: "0.30.6")`, satisfied by the local override |
| `thirdparty/llamacpp_swift` | no | `mlx-swift` dependency is commented out |
| `thirdparty/WhisperKit` | no | only a comment mentions `mlx-swift` |

Both live consumers are gated by building the iOS + macOS schemes against the fork.

---

## Verification gate (run after any change to these repos)

```bash
# 1. No GitHub mlx-swift resolves
xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistant -resolvePackageDependencies
grep -c 'ml-explore/mlx-swift' AIAssistant.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved  # must be 0

# 2. Both schemes build (Xcode required for Metal shaders)
xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistant    -destination "platform=iOS Simulator,name=iPhone 17 Pro Max" build
xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistantMac -destination "platform=macOS" build

# 3. Bit-exact + low-bit gate (Metal needs Xcode; swift test will NOT build the metallib)
cd thirdparty/mlx-swift
xcodebuild test -scheme mlx-swift-Package -destination "platform=macOS" -only-testing:MLXTests/QuantizationTests
```

Last run: 2026-09-28 — steps 1 and 2 green: `Package.resolved` `ml-explore/mlx-swift` count 0,
iOS scheme (iPhone 18 Pro Max simulator) BUILD SUCCEEDED, macOS scheme BUILD SUCCEEDED. Step 3
(`QuantizationTests`) was not re-run because the PrismML patch base did not move (`Package.swift`
byte-identical across `tag-20260918` → `tag-20260928`). MLX model regression suite
(`helper/scripts/model_regression/run_model_tests.py --mlx-only`, Swift engine): plain 14 passed / 0
failed / 2 skipped (`fixed: LFM2.5-2.6B-4bit` against `20260918-113733`); tool-call 11 / 1 / 4
(`fixed: LFM2.5-2.6B-4bit`; the one failure, `MiniCPM5-1B-4bit` "no tool call emitted", is
unchanged from `20260918-114710`). App suites in `testcases/engines/local/` on the iOS simulator:
`MLXAssistantReplayTests` 4, `MLXFinalStatsTests` 10, `MLXKVCacheEstimateTests` 14,
`MLXMemoryBudgetTests` 22, `MLXPromptCacheReuseTests` 33, `LocalEngineStreamStrippingTests` 15,
`LocalOutputCapPrecedenceTests` 9, `LocalClientStatusFieldsTests` 29,
`BackgroundLocalModelIsolationTests` 6 (+1 skip), `LoadAIChatModelFreeingTests` 6,
`BonsaiImageMemoryEnvelopeTests` 3, `LocalModelBenchmarkPOCTests` 2 (+1 skip): all green. On macOS
(Metal): `BonsaiLowBitInferenceTests` 3/3, covering the 1-bit and both 2-bit ternary models.
`MLXVLMLongPromptTests` had never run before 2026-09-28: the file was never in `project.pbxproj`.
It is now wired into `AIAssistantUnitTests` and `AIAssistantMacUnitTests`. **Run it on macOS**,
because its slicing-math cases build `MLXArray`s, and on the simulator that aborts the test host
(it now skips there instead):
`xcodebuild test -project AIAssistant.xcodeproj -scheme AIAssistantMacUnitTests -destination
"platform=macOS" -only-testing:AIAssistantMacUnitTests/MLXVLMLongPromptTests`. First run: the six
`ChunkedPrefill.swift` math cases passed; the 12 model cases are env-gated placeholders and skip.

Last full run (all three steps): 2026-09-18 — all steps green. `Package.resolved` `ml-explore/mlx-swift` count 0;
iOS scheme BUILD SUCCEEDED; macOS scheme BUILD SUCCEEDED; `QuantizationTests` **5/5 passed**
(`testBitExactRegression`, `testLowBitReconstruction`, plus the three shape-desc cases). The
`tag-20260831` → `tag-20260918` range moved neither our fork's base nor upstream's requirement —
`Package.swift` is byte-identical across it — so the PrismML patch base is untouched; the gate was
re-run anyway because the merge changed `mlx-audio-swift` (see the 2026-09-18 history row).

Package-level `swift test` in `mlx-swift-lm` is green apart from `AllowedToolOutputRouterTests`
(2 issues, event-splitting in `ordinaryTagLikeTextRemainsAResponse` /
`nearProtocolMarkersSuppressWithoutStrippingOrdinaryTags`). Confirmed **pre-existing upstream
failures** by running that suite in a detached worktree of `origin/main` `c6446cf`: upstream ships
red on exactly those two, and no fork code is on their path. Do not treat them as a fork
regression on the next merge.

> `swift test --filter QuantizationTests` reports "0 tests passed" and an MLX "Failed to load the
> default metallib" error. That is the documented `swift test` limitation, not a failure — use the
> `xcodebuild test` line above.

---

## Upgrade history

| Date | mlx-swift-lm | mlx-swift (Swift / core) | Patch action |
|------|--------------|--------------------------|--------------|
| 2026-06-22 | `tag-20260621` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | Initial self-managed-fork setup; PrismML 1-bit/2-bit patch applied; no version move from the previous `tag-20260616→tag-20260621` merge |
| 2026-07-03 | `tag-20260703` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | No version move — PrismML patch unaffected. Merge resolved the Qwen2-VL M-RoPE (#345) vs. iOS chunked-prefill overlap (hybrid split: image path single-shot, text-only chunked); all 7 VLM `chunkedVLMPrefill` patches preserved. iOS scheme BUILD SUCCEEDED; macOS + QuantizationTests not re-run (patch base untouched) |
| 2026-07-14 | `tag-20260714` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | No version move — PrismML patch unaffected. Merge brought VLM correctness fixes (Qwen3.5-VL sanitize #403, Qwen3-VL sRGB tone curve #411, Qwen2.5-VL prefill state carry #419, Gemma 4 KV-shared load #390), Gemma 3 fast prompt prefill #346, Gemma tool-arg typing #388, and safetensors-index loading #408. Only conflict was `Load.swift` (#408): resolved to upstream's index loop with the fork's nil-enumerator guard preserved. All 11 VLM `chunkedVLMPrefill` patches intact. iOS scheme BUILD SUCCEEDED; macOS + QuantizationTests not re-run (patch base untouched) |
| 2026-07-22 | `tag-20260722` | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | Backfilled row — this upgrade shipped but was never recorded here. No mlx-swift *version* move, but upstream's merged code needed two 0.31.5-only APIs (`DType.greatestFiniteMagnitudeArray`, `MLXArray.maskFill`, #429). A full 0.31.5 bump would have dragged in the iOS-hostile `encuda`/`CudaBuild` build-tool plugin (#430), so only commit #429 was cherry-picked onto `prism-1bit-0.31.4` (`37b3ca1`) — `DType.swift` plus a 14-line `MLXArray+maskFill.swift`, no quant shaders, no vendored-core change. Merge adopted upstream's Qwen3.5 windowed prefill (#399) wholesale, retiring that fork patch. iOS + macOS BUILD SUCCEEDED |
| 2026-08-10 | `tag-20260810` | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | No version move — PrismML patch unaffected. Upstream replaced `prepare(_:cache:state:windowSize:)` with `prepare(_:cache:state:prefill:)` and added the generic `PrefillParameters.forEachChunk` driver (#470, balanced chunking, ~9% off full prefill at 32K). **Eight VLM fork patches retired** (FastVLM, Pixtral, LFM2VL, Gemma3, Mistral3, Idefics3, Qwen25VL, Qwen2VL) because upstream now chunks them on every platform; only Qwen3VL + GlmOcr keep `chunkedVLMPrefill`, which itself now delegates to `forEachChunk` and is `throws`. `Gemma3.swift`/`Mistral3.swift` auto-merged into non-compiling code with no conflict marker — the recurring trap. Also: `ToolCallFormat.infer` deleted in favor of per-model `ChatConventionsProviding` (#502/#482), typed KV cache configuration (#453), Harmony/gpt-oss tool parsing (#146), Qwen3.5/3.6 compiled decode (#467/#468/#469). App side: `prefill.stepSize` + new `prefill.progress` instrumentation, typed `ToolCall` in `Chat.Message`. iOS + macOS BUILD SUCCEEDED; QuantizationTests not re-run (patch base untouched) |
| 2026-08-31 | `tag-20260831` (`af35aee`) | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | **No fork move — but upstream's requirement moved.** `mlx-swift-lm` PR #484 raised its pin to `.upToNextMinor(from: "0.31.6")`; the API it needed is #429, already cherry-picked onto `prism-1bit-0.31.4`. Audited every other `0.31.4→0.31.6` delta as Linux/CUDA plumbing, training-only optimizers or complex64 `finfo` — none reachable. PrismML patch untouched; gate re-run anyway: iOS + macOS BUILD SUCCEEDED, `QuantizationTests` 5/5. **Last two VLM fork patches retired** (Qwen3VL, GlmOcr) — upstream PR #475 gives each its own windowed `prepareContinuation`, so `MLXVLM/Models/` is byte-identical to upstream for the first time. 13 conflicts resolved; `Chat.Message.name` folded into upstream's typed `Tool.result(id:name:)`; declared-tool authorization moved to `ToolCallProcessor.allowedToolNames`; `pendingOutput` drain relocated into `processEOSOutputs()` so `TokenStreamDecoder.swift` is byte-identical. Three breaks with **no conflict marker**: `ToolTests.swift` duplicate `testGemma4FormatProcessor`, and the newly-`throws` `newCache`/`makePromptCache` family breaking `mlx-audio-swift/CSMModel.swift` **and** `AIChatModelMLX.applyPromptCacheReuse`. App side: PR #475's fail-closed continuation would have broken **every warm-cache VLM turn** — both predict paths now catch `ContinuationStateError` and rebuild at full prompt length |
| 2026-09-18 | `tag-20260918` (`2e4417d`) | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | **No version move — `Package.swift` byte-identical across the range; PrismML patch unaffected.** 17 upstream PRs. The cycle is dominated by #548 (bounded cross-dialect tool-call recovery), which rewrote the streaming tool-call layer all three fork-local tool patches attach to: a `TextToolCallRecoveryScanner` now runs **ahead of** the selected parser and re-splits chunks at dialect-signal boundaries, `scanTaggedStart` replaced the anchored `partialMatch` branch, `ToolCallPolicy` arrived on `GenerateParameters`, and `ToolArgumentNormalization` + `ToolSchemaValidator` gate every call at one admission boundary. Six conflicts resolved by threading `fallbackParser` and `toolCallPolicy` together rather than choosing; the `JSONToolCallParser` XMLFunction fallback had to move onto the framed content because upstream's rewritten `XMLFunctionParser` now demands a payload starting with `<function=`. **Five fork patches broke with no conflict marker** — `generateRecordingTokens` not forwarding `toolCallPolicy`; the recovery pass-through fast path bypassing `pendingOutput`; the legacy `processEOS` never draining it; the hold surviving a confirmed start tag (emitting pre-call text after the call); and the hold covering every `.normal` chunk, which only became visible once the scanner started pre-splitting. Also #620 (`clearCache()` moved onto the first generated token — looked like a re-introduction of the per-generation clear this app deleted in 2026-07-26, so it was **measured**: interleaved in-process A/B on `Qwen3.5-4B-MLX-4bit`, 256-token prompt / 48-token generation, `cacheLimit` pinned to 1 GB — upstream's cadence is **7-13% faster** across three readings, pool ~90 MB vs ~900 MB. The 2026-07-26 finding cleared *before* prefill at a 20 MB cacheLimit and does not transfer. **Do not fork-patch it.**), #611 (generation on a dedicated serial executor), #579 (async `loadWeights`), #515 (`PreparedInputSplitting`, `Qwen25VL` only — no shipped model conforms and the rule lives in `ChatSession`, which this app does not use), #584 (wrap-aware `RotatingKVCache.trim`), #613 (scalar-wise detokenizer prefix, fixes repeating ZWJ emoji), #615, #589, #471, #602, #596, #597, #591, #599, #605, #616. One break with **no conflict marker outside this repo**: #589's `CompileOverloads.swift` publishes `@Sendable`-bodied `compile` overloads that shadow `MLX.compile` in any file importing `MLXLMCommon`, breaking `mlx-audio-swift/ParakeetModel.swift` — both call sites qualified to `MLX.compile`. iOS + macOS BUILD SUCCEEDED; `QuantizationTests` 5/5; app suites `ToolCallParserTests` 84, `ToolCallParserChainTests` 23, `Gemma4ToolCallParserTests` 7, `MLXFinalStatsTests` 10, `MLXPromptCacheReuseTests` 33 — all green |
| 2026-09-28 | `tag-20260928` (`2495a6f`) | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | **No version move — PrismML patch unaffected.** One upstream PR, #603, entirely inside `MLXFoundationModels` (model-cache extraction, `evictAll()` cancels in-flight loads, per-model `MLXDownloadProgress`), which the app does not link; `MLXLMCommon` / `MLXLLM` / `MLXVLM` / `Package.swift` byte-identical, no conflicts. Post-merge MLX regression was identical to 2026-09-18. It had one real, pre-existing failure, and this cycle fixed it fork-locally: `LFM2.5-2.6B-4bit` (prod catalogue) never loaded. `LFM2Model.sanitize` now strips a `language_model.` prefix, and `LFM2Configuration` reads `intermediate_size` when `block_ff_dim` is absent. The second defect only appeared once the first was fixed. Also fixed the regression harness reusing a stale macOS host on a dirty tree. iOS + macOS BUILD SUCCEEDED; regression plain 14/0/2, tool-call 11/1/4, both `fixed: LFM2.5-2.6B-4bit` with no regressions; `QuantizationTests` not re-run (patch base untouched) |

---

## How to upgrade (recurring, every 7-10 days)

Use the **`mlx-swift-lm-upgrade`** skill (`helper/skills/mlx-swift-lm-upgrade/`). Triggers: "upgrade mlx-swift-lm",
"merge mlx-swift-lm", "weekly MLX upgrade", a new `tag-YYYYMMDD`. It: merges upstream + resolves the recurring
`MLXVLM/Models/*.swift` + `ChunkedPrefill.swift` conflicts, creates the dated `tag-<today>` branch, writes
`commit.log` + `whatsnew.md`, updates `LocalModelEngineInfo.mlxSwiftInfo`, adds a release note, and — the critical
step 7 — re-reads `Package.swift` live, reconciles the `mlx-swift`/`mlx-core` versions, re-applies the PrismML patch
onto the new base if the version moved, and re-runs the verification gate. **Append a row to the Upgrade history
table above and refresh "Current state" each time.**

Reference: `helper/docs/mlx-swift.md` → "Self-managed MLX forks" and "Checklist when merging upstream changes".
