# mlx-swift-lm Upgrade — `tag-20261024` → `tag-20261030`

**Merged:** 2026-10-30
**Upstream base:** `ml-explore/mlx-swift-lm` main (15 upstream PRs: #563, #703, #712, #720, #723, #728, #730, #731, #732, #735, #736, #737, #740, #745, #746)
**Old fork tip:** `742620475` · **New:** `0c150ad` (merge of upstream/main)
**Dependencies moved (forced by #720):** mlx-swift 0.32.3 → **0.33.0** (`prism-1bit-0.33.0` @ `02a4a944`), mlx core v0.32.2 → **v0.32.4** (`prism-1bit-0.32.4` @ `743ae9056`)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

15 upstream commits, plus a dependency move. #720 raises the floor to mlx-swift 0.33.0, which carries mlx core
v0.32.4 (181 core commits since v0.32.2). The most important item for our iOS integration is that move.
Upstream mlx now ships its own 1-bit affine kernels (#3161, written by PrismML's author). These replace the
kernels from our PrismML patch that the Bonsai rows run on. Only the bias-free `affine_sym` path is still
fork-only. The move also brings two Metal fence deadlock fixes (#4552, #4689), an eval-cleanup deadlock fix
(#4556), and an iOS 26.2 launch crash fix in mlx-swift (#494). Within mlx-swift-lm itself, Qwen 3.5 now
runs its gated-delta layers on mlx core's new fused kernel (#740). Upstream `generate()` now splits thinking
into `.reasoning` events (#563). The app's `generateRecordingTokens` path deliberately stays unwired. Nothing
here blocks shipping once the regression gate and the FLUX parity suites pass.

---

## Highlights

### On-device / iOS memory & stability
- **Gated-delta layers on mlx core's fused kernel (#740).** `gatedDeltaUpdate` uses `MLXFast.gatedDeltaUpdate`
  when the inputs have no mask, head dim 128 and a supported (Hk, Hv) pair: (16,16), (16,32), (16,48), (16,64),
  (24,24) or (32,32). Queries and keys are passed in float32 to avoid mlx#4725, where bf16 decay rounds to 1.
  Upstream measures prefill up to 1.9x faster per layer, with decode unchanged. This applies to every Qwen3.5
  row (0.8B/2B/4B), the LLM and the VLM path alike.
- **Concurrency fixes from mlx-swift 0.33.0:** synchronous `eval` no longer holds `evalLock` (#474), a lock
  inversion between `evalLock` and `globalStreams` is fixed (#499), a sibling-array leak on every
  `Module.update(parameters:)` model load is fixed (#501), and `asArray` on zero-size arrays no longer crashes (#486).
- **Fixes from mlx core v0.32.4:** Metal fence deadlocks (#4552, #4689), an eval-cleanup deadlock (#4556),
  foreign buffer ownership (#4634), ResidencySets reading an autoreleased error (#4623), and 32-bit grid
  overflow in reductions (#4437). SDPA memory is lower for head dims 256 and 512 (#4505, #4487, #4518). This
  matters for Gemma 4's global layers. The SDPA threadgroup size is fixed for M1/M2-class GPUs (#4643).
- **`GPU.deviceInfo()` is computed once and picks the device the way MLX does (#498).**
- **Safetensors loading (mlx-swift #462, #427):** `loadArrays(urls:)` loads several files concurrently in
  file-offset order, and `withLoadProgressHandler` reports load progress in bytes. The app does not call either yet.

### New models
- **Nemotron 3.5 Lightning (30B-A3B) and Bolt (74B-A9B, `nemotron_h_puzzle`) (#712).** These add latent MoE
  experts and per-layer `block_configs`, and skip the MTP head. All are far above the 4B ceiling. The
  catalogue has no candidate here.
- **Side effect of #712:** the Nemotron-H reasoning config (`enable_thinking`) is now declared, which also
  covers the dense Nemotron 3 Nano 4B. **`mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit`** (`nemotron_h`,
  about 4B params, 2.24 GB) is the only ≤4B candidate this cycle. Its tool format is `.xmlFunction`, so the
  row would use the Qwen3-Coder / xml_function bridge id (P8).
- `NVIDIA-Nemotron-3.5-Bolt-E4B` is a `gemma4`-architecture checkpoint (about 7.5B total, OptiQ mixed
  precision only on mlx-community). It is not a candidate.

### New capabilities / API
- **Reasoning events (#563):** `Generation.reasoning`, `ReasoningConfig.channel` for Gemma 4's labelled
  `<|channel>thought` blocks, and a `<think>` config for Qwen3/3.5, Nemotron-H and others. Only upstream
  `generate()` / `ChatSession` emit them. **The fork's `generateRecordingTokens` (the app's call) does not
  pass `reasoning:`, which is deliberate (coordinator decision), so the app still sees thinking in `.chunk`.**
- **`ModelMemory` / `ModelContainer.memory()` (#746):** model weight bytes measured from the buffers, with
  each buffer counted once (uses `Memory.bufferSize`, new in mlx-swift 0.33).
- **Qwen 3.5 text geometry is readable (#737).** Gemma 4 VLM gains `hiddenStates(_:)` at
  `@_spi(GemmaEncoder)` (#730), and `prepare` now goes through the same helper.
- Products the app does not link: `MLXLanguageModel` prefill step size (#745), `GrammarConstraint.freshMatcher()`
  (#732), and the guided loop now feeds the sampled token before its fast-forward tokens (#731).

### Correctness fixes
- **Attention masks are sized by the cache, not the absolute offset (#728).** `createAttentionMask(h:cache:)`
  delegates to `cache.first.makeMask`. Qwen3-VL-MoE builds one shared mask, and Gemma2 boolean masks
  now suppress keys instead of adding to the scores.
- **Prefill over a quantized KV cache uses the fused SDPA kernel for L ≥ 64 (#703)**, for head dims
  64/72/80/96/128.
- Gemma 3 RoPE scaling is read from `rope_parameters` (#723). FastVLM's negative image sentinels are kept
  out of the repetition-penalty history (#735). Bert `id2label` key collisions now throw instead of trapping (#736).
- Core: split-K quantized matmul partials are kept in float32 (#4641), the fast qmv kernel handles outputs not
  divisible by 8 (#4516), qvm_split_k batched row count is fixed (#4673), sigmoid now matches between compiled
  and eager runs (#4461), and fp quantized matmul corruption when K % 32 != 0 is fixed (#3912).

### Build / toolchain
- `Package.swift` still uses `.package(path: "../mlx-swift")`. Upstream requires `.upToNextMinor(from: "0.33.0")`.
  mlx-swift-lm's `CompileOverloads.swift` is deleted, because mlx-swift's own `compile` now returns `@Sendable`
  closures from `@Sendable` inputs (#469). A `compile { }` that captures a `Module` without `inputs:` no longer
  compiles.
- mlx-swift #494 removes the `cLogSupport` target. #418 adds `MaterializedArray`, a Sendable `MLXArray` subtype, and #510
  restores `update(parameters:)` recursion. mlx-c is v0.8.0 (`a26f2d58`). mlx core fixes cooperative-tensor
  builds on macOS 27 (#4594).
- `thirdparty/mlx-audio-swift` is now compiled against mlx-swift 0.33.0 through the local override, even though its own
  manifest says `from: "0.32.3"`. Its `compile` wrappers already take `@Sendable` closures, and Parakeet passes `inputs:`.

### Tests
- New upstream: `ModelMemoryTests`, `NemotronHTests`, `Gemma2Tests`, `Gemma3RopeParametersTests`,
  `Qwen35ContinuationTests`, `Qwen3VLMoEContinuationTests`, `Qwen3EmbedderMaskTests`,
  `Gemma4VLMHiddenStatesTests`, `FreshMatcherTests`, `GuidedForwardStateTests`, `PrefillStepSizeTests`,
  plus quantized-KV prefill cases in `KVCacheTests`, and `GatedDeltaTests` expanded.
- Fork gate (P3/P4): `swift build` OK, and `ToolTests|TokenStreamDecoder|ChatTests` 119 passed. mlx-swift
  `QuantizationTests` 11/11, including the 3 PrismML gates (`testBiasFreeLowBitMatchesDerivedBias`).

---

## Fork-local work this cycle

### Conflicts and fork patches (P3)
- 5 conflicts: `Package.swift`, `Evaluate.swift`, `TokenLoopHandler.swift`, `TokenStreamDecoder.swift` and
  `ToolCallFormat.swift`. `fallbackParser` sits before upstream's `toolCallPolicy, reasoning` on every
  signature in the chain `TextToolTokenLoopHandler → makeTokenStreamDecoder → StandardTokenStreamDecoder →
  ToolCallProcessor`. Every line the fork added is still present. There are 27 files with `wangqi modified` markers (26 before).
- Gemma4FunctionParser, the Gemma4Processor assistant+tool merge, and the LFM2/LFM2VL/Paligemma fixes are kept, because
  upstream #563 did not change Gemma 4 tool-call parsing.
- `chunkedVLMPrefill` still has no production callers. Gemma4 and Qwen3-VL-MoE multimodal `prepare` are still
  single-shot, as before. No VLM prefill patch was added or dropped.

### Dependency reconciliation (P4)
- mlx core `prism-1bit-0.32.4` (base v0.32.4 `36969c094`): upstream #3161 **is** PrismML commit 1 plus commit 2's
  `K == 64 && bits >= 2` qmv_quad guard. Both cherry-picks resolved to the base and were skipped as empty.
  Only the bias-free `affine_sym` work is still fork-only: `5c30ce419` (host), `1c0bb0310` (kernel port, now 7
  template args after #4516's `partial_rows`), and `743ae9056` (PRISM-PATCH.md).
- **Gap closed:** `use_qmv_wide` used to route `affine_sym` with `2 ≤ M < vector_limit` to a non-existent
  `affine_sym_qmv_wide` kernel, which failed at JIT. It has done so since `prism-1bit-0.32.2`. `dispatch_qmv` now
  excludes it.
- mlx-swift `prism-1bit-0.33.0` @ `02a4a944` (base tag 0.33.0 `7ede4fd6`): `.gitmodules` → wangqi/mlx, the
  FMT_CONSTEVAL block, the core gitlink, 2 regenerated files (`mlx-generated/metal/quantized.{h,cpp}`; the
  `quantized_nax.*` files no longer differ), and 3 fork quantization tests.

### Reasoning events: decision
`generateRecordingTokens` does not pass `reasoning:` (commented in place at `Evaluate.swift`), so app behaviour
is unchanged. `AIChatModelMLX` reads only `event.chunk` and parses `<think>` and Gemma channels itself.
Wiring it end to end is listed under Follow-ups as an opportunity.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Bonsai 1-bit rows | Now run upstream's 1-bit affine kernels (#3161). Same math, unrolled, plus a tail block |
| Ternary-Bonsai 2-bit / `affine_sym` | Fork kernels kept; 2 ≤ M < vector_limit no longer fails at JIT |
| Qwen3.5 0.8B/2B/4B | Gated delta on mlx core's fused kernel, faster prefill (#740) |
| Gemma 4 E2B | Lower SDPA memory for D256/D512 (core); `prepare` refactored behind `hiddenStates` (#730) |
| Stability | Metal fence and eval deadlocks fixed (core); iOS 26.2 Logger launch crash fixed (#494); eval lock and stream lock fixes |
| Thinking / tool calls | Unchanged on the app path (`generateRecordingTokens` unwired) |
| TurboQuant KV (`turbo0v4`) | Unchanged: #703 only routes `QuantizedKVCache` (`kvBits`), which the app never sets |
| Masks with no rotating cache | Equivalent: `maxKVSize` is always nil in the app (#728) |
| FLUX.2 imagegen / mlx-audio | Same API. Numerics may move slightly (split-K float32 partials #4641, qmv tail #4516) |

---

## Risk Assessment — **6 identified risks** (3 medium, 3 low)

### R1 — Dependency move: Bonsai 1-bit now on upstream kernels, `affine_sym` re-based (MEDIUM)
Every 1-bit affine qmv/qmm call now runs upstream's #3161 kernels instead of PrismML's. The bias-free path was
re-based onto `qmv_fast_impl`'s new `partial_rows` parameter, and the qmv_wide gap was closed. 181 core commits
also changed quantized dispatch (#4516, #4641, #4673, #4629). The kernel gate passed (QuantizationTests 11/11).
*Verify:* `run_model_tests.py --mlx-only --compare <P1>` for all four Bonsai rows (`Bonsai-4B-mlx-1bit`,
`Ternary-Bonsai-{1.7B,4B,8B}-mlx-2bit`), plus `testcases/engines/local/BonsaiLowBitInferenceTests`. Any new
text drift on a Bonsai row is a real finding, not noise.

### R2 — #740 fused gated delta on Qwen 3.5 (MEDIUM)
This is a new mlx core Metal kernel (#4020/#4565). Every Qwen3.5 decode and prefill step that meets the
shape gate now runs it, with float32 q/k casts added per step. Upstream measured on M4 Pro and Qwen3.5-9B
only. Mobile GPUs (A17/A18) and the 0.8B/2B/4B geometries are not covered.
*Verify:* the regression gate for the three Qwen3.5 rows (text and `--tool-call`), and an on-device turn
comparing `[MLX-PERF] prefillTps / decodeTps / peak` against OLD.

### R3 — mlx-swift 0.33 eval/lock rework under concurrent MLX users (MEDIUM)
#474 moves synchronous `eval` out from under `evalLock`. #499 and #4689/#4552 change fence and stream locking.
The app can run MLX LLM, mlx-audio (TTS/ASR/VAD) and FLUX in one process. These are fixes, but they change
timing on exactly the paths that used to deadlock.
*Verify:* `run_audio_tests.py --compare`, the FLUX parity suites (P10), and one manual chat-with-TTS turn on device.

### R4 — FLUX.2 parity tolerances under core numeric changes (LOW)
Split-K partials in float32 (#4641) and the qmv tail fix (#4516) can shift results in the last few bits. The
tolerances are measured against Python. Never loosen one. *Verify:* `Flux2{Block,Transformer,VAE}ParityTests`
and `Flux2PipelineEndToEndImageTests`.

### R5 — #563 changed upstream `generate()`'s stream (LOW, test harness fixed)
Upstream `generate()` now diverts thinking into `.reasoning`. `MLXCatalogueRegressionTests` judged its
plain, chat and vision probes on `event.chunk` from `generate()`, so it no longer saw what the app sees. P7
switched those probes to `generateRecordingTokens`, which is the app's call. The app's benchmark sample
(`runMLXBenchmarkSample`), `LocalModelBenchmarkPOCTests` and `BonsaiLowBitInferenceTests` still call
`generate()`. The first two read only `.info`. Bonsai uses a raw prompt with no thinking opener.

### R6 — #728 mask delegation and #703 quantized-KV prefill (LOW)
With `maxKVSize` nil and no `kvBits`, the app's masks are equivalent and #703 is never taken. Exception: a
hybrid model whose `cache.first` is a non-attention cache now gets that cache's `makeMask`. *Verify:*
`MLXPromptCacheReuseTests`, `MLXKVCacheEstimateTests`, and the LFM2 / granite-4.2 rows in the regression gate.

---

## Follow-ups
1. Build both schemes (`AIAssistant` iOS, `AIAssistantMac`). The iOS build is the only one that compiles the
   `#if os(iOS)` fork paths and mlx-audio-swift against 0.33.0 for iOS.
2. P10 regression with `--compare` (generate and `--tool-call`), the FLUX parity suites, and `run_audio_tests.py`.
   This is required because P4 moved mlx-swift and mlx.
3. P8 candidate: `mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit` (`nemotron_h`, `.xmlFunction`, thinking on by default).
4. Opportunity: wire `.reasoning` end to end. Pass `reasoning:` in `generateRecordingTokens` and handle
   `event.reasoning` in `AIChatModelMLX.consumeMLXStream` by feeding it to the think UI. This also stops tool
   calls fired from inside the thinking block. It needs the `--tool-call` regression in the same change.
5. Opportunity: replace the app's weight-size estimate with `ModelContainer.memory()` (#746) for the memory
   budget log. Use `withLoadProgressHandler` for a byte-accurate MLX load progress bar.
6. P12 docs: UPGRADING.md's "3 PrismML commits" wording now reads "bias-free affine_sym only (upstream #3161
   absorbed commits 1-2)". Record the mlx-swift / mlx axis move.
