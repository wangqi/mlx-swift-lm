# MLX Stack — Versions & Upgrade Status

Records the current pinned state of the three self-managed MLX repos so a future upgrade knows exactly what it is
starting from. Update this file on every upgrade (it is part of the `thirdparty-upgrade` skill's `mlx` deliverables).

**Last updated:** 2026-10-17

> These three are **independent local git repos** under `thirdparty/` (not app submodules). The app
> (`AIAssistant.xcodeproj`) wires them as local SwiftPM packages; a root-level `XCLocalSwiftPackageReference` for
> `thirdparty/mlx-swift` overrides the GitHub `mlx-swift` for **both** live consumers (`mlx-swift-lm` and
> `mlx-audio-swift`). After resolution, `Package.resolved` must contain **no** `ml-explore/mlx-swift` entry.

---

## Current state

| Repo | Remote (origin) | Branch | HEAD | Role |
|------|-----------------|--------|------|------|
| `thirdparty/mlx-swift-lm` | `wangqi/mlx-swift-lm` | `tag-20261017` | `9d6b496` (merge) | LLM/VLM layer (the package upgraded every 7-10 days) |
| `thirdparty/mlx-swift`    | `wangqi/mlx-swift` (+ `upstream` = `ml-explore/mlx-swift`) | `main` (= `prism-1bit-0.32.3`) | `2a7e24b` | Swift API + vendored mlx-core; carries the PrismML patch |
| `thirdparty/mlx`          | `wangqi/mlx` (+ `prism` = `PrismML-Eng/mlx`, `upstream` = `ml-explore/mlx`) | `main` (= `prism-1bit-0.32.2`) | `7591f4029` | mlx-core C++ fork; holds the PrismML 1-bit/2-bit patch |

Since 2026-10-17 `main` in both forks is the PrismML line: it was a stale June snapshot of upstream `main` and an
ancestor of the `prism-1bit-*` branches, so it was fast-forwarded to them. It no longer mirrors upstream; a future
move still branches `prism-1bit-<ver>` off the new release tag and fast-forwards or merges `main` afterwards. The
previous branches (`prism-1bit-0.31.4` @ `37b3ca1`, `prism-1bit-0.31.1` @ `48db7fe5`) are kept for rollback.

### Engine version surfaced in the app
- `LocalModelEngineInfo.mlxSwiftInfo.version` = `"20261017"` (`views/settings/models/LocalModelAboutView.swift`).

---

## The two version axes (do not conflate)

`mlx-swift` carries two independent versions:

| Axis | Value | Where it lives |
|------|-------|----------------|
| **Swift-package version** (git tag / API surface) | **0.32.3** (`1960120`) | the `mlx-swift` release tag our fork branch `prism-1bit-0.32.3` is based on. Upstream `mlx-swift-lm` pins `.upToNextMinor(from: "0.32.3")` (#646, #657) |
| **Vendored mlx-core (C++)** | **v0.32.2** (`1f8e74e`) | `thirdparty/mlx-swift/Source/Cmlx/mlx` gitlink + `mlx/version.h` (`MLX_VERSION 0.32.2`); the base of `thirdparty/mlx` `prism-1bit-0.32.2` |

An older core can back a newer Swift API, so check both axes on every merge: the required tag can move the core
too (`git -C thirdparty/mlx-swift ls-tree <tag> Source/Cmlx/mlx`). 0.32.3 did, which is why 2026-10-17 moved both.

### Base on the release tag, not `mlx-swift` `main`
Releases are the tested combination of Swift sources, mlx-c and mlx-core. The iOS blocker that first forced this
rule, the `Source/Encuda` CUDA plugin (`Foundation.Process`, `API_UNAVAILABLE` on iOS), is behind `#if os(Linux)`
in `Package.swift` since 0.32.x (#437, #447), so it no longer breaks the iOS build. Check the gate is still there on
each move.

### History of the axes
- 2026-06-22 → 2026-10-16: Swift `0.31.4` (`dc43e62`, + #429 cherry-pick `37b3ca1` from 2026-07-22) on core `0.31.1`
  (`ce45c52`). Upstream's 2026-08-31 move to `0.31.6` did not force a fork move: the only reachable API was #429.
- 2026-10-17: Swift `0.32.3` / core `v0.32.2`. Forced by `MLXLogger` (0.32.x), first seen as
  `cannot find 'MLXLogger' in scope` when building the merged code against the 0.31.4 fork.

---

## Fork-local patches in `mlx-swift-lm` (carry these across every upgrade)

Separate from the PrismML patch below, which lives in `mlx` / `mlx-swift`. Each block is marked in
place with `// wangqi modified YYYY-MM-DD`, so `git diff` against the upstream tag finds them.

> **No `MLXVLM/Models/*.swift` file is fork-patched any more (since 2026-08-31).** Qwen3VL and
> GlmOcr, the last two `chunkedVLMPrefill` holdouts, were retired when upstream PR #475 gave each of
> them its own windowed `prepareContinuation`. `Libraries/MLXLMCommon/ChunkedPrefill.swift` stays:
> `testcases/engines/local/MLXVLMLongPromptTests.swift` (macOS only) exercises its slicing math directly, and it is the escape
> hatch for the next model upstream leaves single-shot.

The rest of the fork surface is: `fallbackToolCallParser` threading (Evaluate → `TokenLoopHandler.swift`
`TextToolTokenLoopHandler` → ToolCallFormat → StandardTokenStreamDecoder → ToolCallProcessor), the
`pendingOutput` invisible-start-tag buffer, the Pythonic JSON fallback, `Gemma4FunctionParser` (see
below), `ModelLoadError.directoryNotAccessible`, the `QuantizationBitsError` guard (see below — **it
must keep admitting bits=1**), MLXLogCollector tracing, and the two ChatSession changes below.

> **2026-10-17: upstream #640 moved `TextToolTokenLoopHandler` out of `Evaluate.swift` into
> `TokenLoopHandler.swift`.** Taking upstream's side of that hunk dropped the fork's `fallbackParser`
> init parameter with no conflict marker; it was re-added in the new file. Expect upstream to keep
> moving code; diff a deleted block against the merge base before taking upstream's side.

### `.minicpm5` tool-call format — `MiniCPM5FunctionParser.swift` (new) + `ToolCallFormat.swift` + `ToolCallFormatInference.swift` (2026-10-18)

MiniCPM5 declares `model_type: "llama"` with a 130,560-token vocabulary, so `LlamaModel.toolCallFormat`
(`MLXLLM/Models/Llama.swift`, vocabulary >= 128,000) guessed `.llama3`. Its inline-JSON parser never
reads `<function name="f"><param name="k">v</param></function>` and never consults the fallback
parser, so every MiniCPM5 call was dropped (regression tool-call probe FAIL since 2026-09-28). The
fork adds: a `.minicpm5` case using `MiniCPM5FunctionParser` (start `<function name=`, end
`</function>`, unwraps the `<![CDATA[...]]>` values the template asks for); a template signature
(`<function name="` with `<param name="`, plain or escaped quotes) so `resolved()` replaces the
Llama 3 guess; and `tool_parser_type` `"minicpm5"`. **On upgrade:** keep the case in the three
ordinary-format switch lists in `ToolCallFormat.swift`; drop the patch only if upstream ships its
own MiniCPM5 format. Gate: `-only-testing:MLXLMTests/MiniCPM5FunctionParserTests` plus the MLX
tool-call probe on `MiniCPM5-1B-4bit`.

### `Libraries/MLXLMCommon/Tool/Parsers/Gemma4FunctionParser.swift` — delegate native syntax (2026-10-17)

The fork keeps its own `.gemma4` parser only for the double-brace JSON that the Gemma 4 chat
template produces when it re-injects tool-call history (`call:f{{"k":"v"}}`). Its own scalar-only
key:value loop hid upstream #626 (nested objects and arrays read against the tool schema). It now
tries the JSON fallback first and hands everything else to `GemmaFunctionParser(startTag:
"<|tool_call>", endTag: "<tool_call|>", escapeMarker: #"<|"|>"#)`. **On upgrade:** keep the
delegation; re-add nothing to the fork's own loop. Gate: `swift test --filter ToolTests`
(upstream's nested Gemma 4 tests plus the fork's double-brace / bare-value tests).

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

**2026-10-17:** upstream #679 replaced the inline quantize with component-aware loading
(`prepareComponents` → `loadModelCheckpoint` → `prepareCheckpoint` → `applyCheckpoint`) and folds
`quantization` into `perLayerQuantization`. The guard now runs on that merged value **before**
`prepareComponents`, so components loaded on first use (#580) are covered too, and the error text
lists 1-bit.

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
   Qwen3-VL itself in PR #549, and from FastVLM, Gemma 3, Gemma 4, Mistral 3 and SmolVLM in #700
   (2026-10-17), but **Pixtral, Idefics3, MuseGlimmer, GlmOcr and PaliGemma still attach one**, so the
   relaxation remains load-bearing — do not "resolve" this by taking upstream's assertion.

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

- **`thirdparty/mlx` branch `prism-1bit-0.32.2`** (off `1f8e74e`, v0.32.2): the 3 PrismML-Eng/mlx low-bit commits
  cherry-picked (`729d37373`, `8cc09cb24`, `41bbd1896`), `PRISM-PATCH.md`, and `7591f4029`, which adds the
  bias-free kernels to the core. Scope: quantization path only — `mlx/ops.cpp`, `mlx/primitives.cpp`,
  `backend/cpu/quantized.cpp`, `backend/metal/quantized.cpp`, `backend/metal/jit_kernels.cpp`,
  `backend/metal/kernels/quantized*.h`. Conflicts and their resolutions are listed in `PRISM-PATCH.md`.
- **Bias-free (`affine_sym`) kernels live in the core since 2026-10-17.** Until then
  `affine_sym_qmv_fast` / `affine_sym_qmv` / `sym_derived_bias` existed only in mlx-swift's generated
  `mlx-generated/` files (PrismML's mlx-swift), so `tools/update-mlx.sh` would have deleted them with no build
  error. Ported from PrismML-Eng/mlx `4fc91df60`. After every regeneration,
  `grep -c affine_sym Source/Cmlx/mlx-generated/metal/quantized.h` must be >= 3.
- **`thirdparty/mlx-swift` branch `prism-1bit-0.32.3`** (off the `0.32.3` tag `1960120`), commit `2a7e24b`:
  `Source/Cmlx/mlx` gitlink → `7591f4029`; `Source/Cmlx/mlx-c` at the tag's `ebc88f1`; the 4
  `Source/Cmlx/mlx-generated/` quantized files regenerated by `tools/update-mlx.sh` (nothing else changed);
  `.gitmodules` url → `wangqi/mlx`; `Package.swift` `.define("FMT_CONSTEVAL", to: "")`; `QuantizationTests`.
- **`thirdparty/mlx-swift-lm/Package.swift`**: `mlx-swift` dependency is `.package(path: "../mlx-swift")`.
- **Regression guard:** the delta is additive + gated. bits≥2 host quantize, GPU quantize kernel, and matmul paths
  are unchanged (only `if (bits == 1)` branches and the `bias_free` template default `false`). Proven by
  `thirdparty/mlx-swift/Tests/MLXTests/QuantizationTests.swift` — `testBitExactRegression` (2/4/8-bit),
  `testLowBitReconstruction` (bits=1 binary round-trip; bits=1/2 matmul consistency) and
  `testBiasFreeLowBitMatchesDerivedBias` (`biases: nil` == the explicit derived bias on the `qmv_fast` and
  plain `qmv` paths; the only coverage of the bias-free kernels).

---

## Consumers (regression scope)

| Consumer | Depends on `mlx-swift`? | Notes |
|----------|-------------------------|-------|
| `thirdparty/mlx-swift-lm` | yes (local path dep) | the package this file lives in |
| `thirdparty/mlx-audio-swift` | yes — `MLX`, `MLXNN`, `MLXFast` | pins `.upToNextMajor(from: "0.30.6")`, satisfied by the local override |
| `thirdparty/llamacpp_swift` | no | `mlx-swift` dependency is commented out |
| `thirdparty/WhisperKit` | no | only a comment mentions `mlx-swift` |
| `libs/imagegen/` (FLUX.2, app code) | yes — imports `MLX` directly | runs the binary / ternary Bonsai image checkpoints through the 1/2-bit affine kernels |

All three are gated by building the iOS + macOS schemes against the fork. Behaviour is gated by the MLX model
regression suite (`mlx-swift-lm`), `run_audio_tests.py` (`mlx-audio-swift`) and the `testcases/imagegen/` parity
suites on macOS (FLUX.2).

---

## Verification gate (run after any change to these repos)

```bash
# 1. No GitHub mlx-swift resolves
xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistant -resolvePackageDependencies
grep -c 'ml-explore/mlx-swift' AIAssistant.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved  # must be 0

# 2. Both schemes build (Xcode required for Metal shaders)
xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistant    -destination "platform=iOS Simulator,name=iPhone 18 Pro Max" build
xcodebuild -project AIAssistant.xcodeproj -scheme AIAssistantMac -destination "platform=macOS" build

# 3. Bit-exact + low-bit gate (Metal needs Xcode; swift test will NOT build the metallib)
cd thirdparty/mlx-swift
xcodebuild test -scheme mlx-swift-Package -destination "platform=macOS" \
  -derivedDataPath <scratch>/dd-mlxswift -only-testing:MLXTests/QuantizationTests
```
Always pass `-derivedDataPath`: without it the products land in `thirdparty/mlx-swift/build`, and the next
`tools/update-mlx.sh` fails on `mkdir build`.

Last full run (all three steps + every consumer): 2026-10-17, after both axes moved — all green.
`Package.resolved` `ml-explore/mlx-swift` count 0; macOS and iOS (iPhone 18 Pro Max simulator) BUILD SUCCEEDED;
`QuantizationTests` **11/11** (the three PrismML gates plus upstream's NVFP4 global-scale cases); `mlx-swift-lm`
`swift test --filter "ToolTests|TokenStreamDecoder|ChatTests"` 119 passed. MLX model regression (Swift engine):
generate 15 / 0 / 2 and tool-call 12 / 1 / 4, both **identical** to `20260928-155436` / `20260928-154912` (the
one failure is still `MiniCPM5-1B-4bit` "no tool call emitted"); the 1-bit and three 2-bit Bonsai LLMs pass both
modes. Audio (`run_audio_tests.py`) 19/19. FLUX.2 parity on macOS 55/55, none skipped: full 25-block
transformer 6.48e-3 relative RMS (was 6.5e-3), end-to-end vs. the golden max 141 / mean 1.85 / p99 13 (was
155 / 2.20 / 14), 16x16 block-mean difference 1.2458 (was 1.5583). The heavy image suites skip unless the
checkpoint sits at the path `testcases/imagegen/fixtures/manifest.json` records. Since 2026-10-17 that is
`/Volumes/ssd2t/mlximages/bonsai-image-4B-binary-mlx` (it pointed at the deleted
`~/disk/projects/ai/Bonsai-image-demo/models/`); re-run without any link: 55/55, none skipped.

Previous partial run: 2026-09-28 — steps 1 and 2 green: `Package.resolved` `ml-explore/mlx-swift` count 0,
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

Previous full run (all three steps): 2026-09-18 — all steps green. `Package.resolved` `ml-explore/mlx-swift` count 0;
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
| 2026-10-17 | `tag-20261017` (`9d6b496`) | **`0.32.3` (`1960120`) / `v0.32.2` (`1f8e74e`)** | **Both axes moved — first core move since the fork was created.** 48 upstream PRs; upstream pinned mlx-swift `0.32.3` (#646, #657), which vendors mlx v0.32.2. `thirdparty/mlx` `prism-1bit-0.32.2`: PrismML's 3 commits cherry-picked onto `1f8e74e`, conflicts in `dequantize` (upstream float accumulation), the `dispatch_qmv` `qmv_quad` gate (`!global_scale` + `bits >= 2` at K=64 + `mode != "affine_sym"`) and a deleted CUDA test list, resolved against PrismML's own sync `4fc91df60`. **Trap found:** the bias-free `affine_sym` kernels existed only in mlx-swift's generated files and would have been deleted by `update-mlx.sh`; ported into the core (`7591f4029`). `thirdparty/mlx-swift` `prism-1bit-0.32.3` (`2a7e24b`) off the tag, shaders regenerated (only the 4 quantized files changed), new `testBiasFreeLowBitMatchesDerivedBias`. 7 merge conflicts (`Package.swift`, `Chat.swift`, `Evaluate.swift`, `Load.swift`, `TokenStreamDecoder.swift`, `Gemma4.swift`, `ToolTests.swift`). **Two fork patches broke with no conflict marker:** `fallbackParser` stranded when #640 moved `TextToolTokenLoopHandler` into `TokenLoopHandler.swift`, and `Gemma4FunctionParser` hiding #626's nested-argument parsing (now delegates native syntax to upstream). Bits guard moved ahead of #679's component-aware loading. Gate all green: `QuantizationTests` 11/11, iOS + macOS BUILD SUCCEEDED, regression generate 15/0/2 and tool-call 12/1/4 identical to the previous run, audio 19/19, FLUX.2 parity 55/55 with the golden slightly closer than before |

---

## How to upgrade (recurring, every 7-10 days)

Use the **`thirdparty-upgrade`** skill (`helper/skills/thirdparty-upgrade/`, `/thirdparty-upgrade mlx`). Triggers: "upgrade mlx-swift-lm",
"merge mlx-swift-lm", "weekly MLX upgrade", a new `tag-YYYYMMDD`. It: merges upstream, resolves conflicts and audits for fork
patches that upstream moved or shadowed without a conflict marker, creates the dated `tag-<today>` branch, writes
`commit.log` + `whatsnew.md`, updates `LocalModelEngineInfo.mlxSwiftInfo`, adds a release note, and — the critical
dependency step (P4) — re-reads `Package.swift` live, reconciles the `mlx-swift`/`mlx-core` versions, re-applies the PrismML patch
onto the new base if the version moved (checking the bias-free kernels before regenerating shaders), and re-runs
the verification gate plus the LLM, audio and FLUX.2 regressions. **Append a row to the Upgrade history
table above and refresh "Current state" each time.**

Reference: `helper/docs/mlx-swift.md` → "Self-managed MLX forks" and "Checklist when merging upstream changes".
