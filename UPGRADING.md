# MLX Stack — Versions & Upgrade Status

Records the current pinned state of the three self-managed MLX repos so a future upgrade knows exactly what it is
starting from. Update this file on every upgrade (it is part of the `mlx-swift-lm-upgrade` skill's deliverables).

**Last updated:** 2026-08-10

> These three are **independent local git repos** under `thirdparty/` (not app submodules). The app
> (`AIAssistant.xcodeproj`) wires them as local SwiftPM packages; a root-level `XCLocalSwiftPackageReference` for
> `thirdparty/mlx-swift` overrides the GitHub `mlx-swift` for **both** live consumers (`mlx-swift-lm` and
> `mlx-audio-swift`). After resolution, `Package.resolved` must contain **no** `ml-explore/mlx-swift` entry.

---

## Current state

| Repo | Remote (origin) | Branch | HEAD | Role |
|------|-----------------|--------|------|------|
| `thirdparty/mlx-swift-lm` | `wangqi/mlx-swift-lm` | `tag-20260810` | `f544b17` | LLM/VLM layer (the package upgraded every 7-10 days) |
| `thirdparty/mlx-swift`    | `wangqi/mlx-swift`    | `prism-1bit-0.31.4` | `37b3ca1` | Swift API + vendored mlx-core; carries the PrismML patch |
| `thirdparty/mlx`          | `wangqi/mlx` (+ `prism` = `PrismML-Eng/mlx`) | `prism-1bit-0.31.1` | `48db7fe5` | mlx-core C++ fork; holds the PrismML 1-bit/2-bit patch |

### Engine version surfaced in the app
- `LocalModelEngineInfo.mlxSwiftInfo.version` = `"20260810"` (`views/settings/models/LocalModelAboutView.swift`).

---

## The two version axes (do not conflate)

`mlx-swift` carries two independent versions:

| Axis | Value | Where it lives |
|------|-------|----------------|
| **Swift-package version** (git tag / API surface) | **0.31.4** (`dc43e62`) + the #429 cherry-pick (`37b3ca1`) | the `mlx-swift` release commit our fork branch `prism-1bit-0.31.4` is based on; what upstream `mlx-swift-lm` pins via `.upToNextMinor(from: "0.31.4")`. The single additive commit on top (`DType.greatestFiniteMagnitudeArray` + `MLXArray.maskFill`, taken 2026-07-22) avoids the full 0.31.5 bump and its iOS-hostile `CudaBuild` plugin |
| **Vendored mlx-core (C++)** | **0.31.1** (`ce45c52`) | `thirdparty/mlx-swift/Source/Cmlx/mlx` submodule + `mlx/version.h` (`MLX_VERSION 0.31.1`); = PrismML's patch base |

A 0.31.1 core backs a 0.31.4 Swift API. Keep the **core at the PrismML base (0.31.1)** and base the **Swift sources
on the 0.31.4 release** unless upstream forces a move.

### Why the Swift sources are based on the 0.31.4 *release* (`dc43e62`), not `mlx-swift` `main`
`mlx-swift` `main` HEAD (`e23ae6b`) is past 0.31.4 and ships a CUDA build-tool plugin `Source/Encuda` that uses
`Foundation.Process` — `API_UNAVAILABLE` on iOS — which hard-fails the iOS build (`cannot find type 'Process'`).
The tagged 0.31.4 release has no `Encuda` target, so it is the safe base.

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

Last full run: 2026-08-10 — iOS + macOS BUILD SUCCEEDED. `QuantizationTests` not re-run: the
`tag-20260722` → `tag-20260810` range moved neither the `mlx-swift` requirement nor the vendored
core, so the PrismML patch base is byte-identical to the 2026-06-22 run that passed it.

---

## Upgrade history

| Date | mlx-swift-lm | mlx-swift (Swift / core) | Patch action |
|------|--------------|--------------------------|--------------|
| 2026-06-22 | `tag-20260621` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | Initial self-managed-fork setup; PrismML 1-bit/2-bit patch applied; no version move from the previous `tag-20260616→tag-20260621` merge |
| 2026-07-03 | `tag-20260703` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | No version move — PrismML patch unaffected. Merge resolved the Qwen2-VL M-RoPE (#345) vs. iOS chunked-prefill overlap (hybrid split: image path single-shot, text-only chunked); all 7 VLM `chunkedVLMPrefill` patches preserved. iOS scheme BUILD SUCCEEDED; macOS + QuantizationTests not re-run (patch base untouched) |
| 2026-07-14 | `tag-20260714` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | No version move — PrismML patch unaffected. Merge brought VLM correctness fixes (Qwen3.5-VL sanitize #403, Qwen3-VL sRGB tone curve #411, Qwen2.5-VL prefill state carry #419, Gemma 4 KV-shared load #390), Gemma 3 fast prompt prefill #346, Gemma tool-arg typing #388, and safetensors-index loading #408. Only conflict was `Load.swift` (#408): resolved to upstream's index loop with the fork's nil-enumerator guard preserved. All 11 VLM `chunkedVLMPrefill` patches intact. iOS scheme BUILD SUCCEEDED; macOS + QuantizationTests not re-run (patch base untouched) |
| 2026-07-22 | `tag-20260722` | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | Backfilled row — this upgrade shipped but was never recorded here. No mlx-swift *version* move, but upstream's merged code needed two 0.31.5-only APIs (`DType.greatestFiniteMagnitudeArray`, `MLXArray.maskFill`, #429). A full 0.31.5 bump would have dragged in the iOS-hostile `encuda`/`CudaBuild` build-tool plugin (#430), so only commit #429 was cherry-picked onto `prism-1bit-0.31.4` (`37b3ca1`) — `DType.swift` plus a 14-line `MLXArray+maskFill.swift`, no quant shaders, no vendored-core change. Merge adopted upstream's Qwen3.5 windowed prefill (#399) wholesale, retiring that fork patch. iOS + macOS BUILD SUCCEEDED |
| 2026-08-10 | `tag-20260810` | `0.31.4` (`dc43e62` + `37b3ca1`) / `0.31.1` (`ce45c52`) | No version move — PrismML patch unaffected. Upstream replaced `prepare(_:cache:state:windowSize:)` with `prepare(_:cache:state:prefill:)` and added the generic `PrefillParameters.forEachChunk` driver (#470, balanced chunking, ~9% off full prefill at 32K). **Eight VLM fork patches retired** (FastVLM, Pixtral, LFM2VL, Gemma3, Mistral3, Idefics3, Qwen25VL, Qwen2VL) because upstream now chunks them on every platform; only Qwen3VL + GlmOcr keep `chunkedVLMPrefill`, which itself now delegates to `forEachChunk` and is `throws`. `Gemma3.swift`/`Mistral3.swift` auto-merged into non-compiling code with no conflict marker — the recurring trap. Also: `ToolCallFormat.infer` deleted in favor of per-model `ChatConventionsProviding` (#502/#482), typed KV cache configuration (#453), Harmony/gpt-oss tool parsing (#146), Qwen3.5/3.6 compiled decode (#467/#468/#469). App side: `prefill.stepSize` + new `prefill.progress` instrumentation, typed `ToolCall` in `Chat.Message`. iOS + macOS BUILD SUCCEEDED; QuantizationTests not re-run (patch base untouched) |

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
