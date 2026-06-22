# MLX Stack — Versions & Upgrade Status

Records the current pinned state of the three self-managed MLX repos so a future upgrade knows exactly what it is
starting from. Update this file on every upgrade (it is part of the `mlx-swift-lm-upgrade` skill's deliverables).

**Last updated:** 2026-06-22

> These three are **independent local git repos** under `thirdparty/` (not app submodules). The app
> (`AIAssistant.xcodeproj`) wires them as local SwiftPM packages; a root-level `XCLocalSwiftPackageReference` for
> `thirdparty/mlx-swift` overrides the GitHub `mlx-swift` for **both** live consumers (`mlx-swift-lm` and
> `mlx-audio-swift`). After resolution, `Package.resolved` must contain **no** `ml-explore/mlx-swift` entry.

---

## Current state

| Repo | Remote (origin) | Branch | HEAD | Role |
|------|-----------------|--------|------|------|
| `thirdparty/mlx-swift-lm` | `wangqi/mlx-swift-lm` | `tag-20260621` | `a53f021` | LLM/VLM layer (the package upgraded every 7-10 days) |
| `thirdparty/mlx-swift`    | `wangqi/mlx-swift`    | `prism-1bit-0.31.4` | `5e97310` | Swift API + vendored mlx-core; carries the PrismML patch |
| `thirdparty/mlx`          | `wangqi/mlx` (+ `prism` = `PrismML-Eng/mlx`) | `prism-1bit-0.31.1` | `48db7fe5` | mlx-core C++ fork; holds the PrismML 1-bit/2-bit patch |

### Engine version surfaced in the app
- `LocalModelEngineInfo.mlxSwiftInfo.version` = `"20260621"` (`views/settings/models/LocalModelAboutView.swift`).

---

## The two version axes (do not conflate)

`mlx-swift` carries two independent versions:

| Axis | Value | Where it lives |
|------|-------|----------------|
| **Swift-package version** (git tag / API surface) | **0.31.4** (`dc43e62`) | the `mlx-swift` release commit our fork branch `prism-1bit-0.31.4` is based on; what upstream `mlx-swift-lm` pins via `.upToNextMinor(from: "0.31.4")` |
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
- **`thirdparty/mlx-swift` branch `prism-1bit-0.31.4`** (off `dc43e62`): `Source/Cmlx/mlx` gitlink → `48db7fe5`;
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

Last full run: 2026-06-22 — iOS + macOS BUILD SUCCEEDED; QuantizationTests TEST SUCCEEDED.

---

## Upgrade history

| Date | mlx-swift-lm | mlx-swift (Swift / core) | Patch action |
|------|--------------|--------------------------|--------------|
| 2026-06-22 | `tag-20260621` | `0.31.4` (`dc43e62`) / `0.31.1` (`ce45c52`) | Initial self-managed-fork setup; PrismML 1-bit/2-bit patch applied; no version move from the previous `tag-20260616→tag-20260621` merge |

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
