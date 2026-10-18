# mlx-swift-lm Upgrade — `tag-20260928` → `tag-20261017`

**Merged:** 2026-10-17
**Upstream base:** `ml-explore/mlx-swift-lm` main @ `48114ee` (48 upstream PRs, #301–#705)
**Local integration doc:** `helper/docs/mlx-swift.md`
**Primary consumer:** `ai/AIChatModelMLX.swift`

The largest upgrade since the fork moved to self-managed MLX, and the first to move **both**
dependency axes. Upstream now requires `mlx-swift` `.upToNextMinor(from: "0.32.3")` (#646, #657), and
the 0.32.3 tag vendors mlx-core **v0.32.2** (`1f8e74e`) instead of 0.31.1. The PrismML 1-bit/2-bit
patch was therefore rebased in both forks (`thirdparty/mlx` `prism-1bit-0.32.2`, `thirdparty/mlx-swift`
`prism-1bit-0.32.3`). On the way, the bias-free `affine_sym` kernels turned out to exist only in
mlx-swift's generated shader files; they were ported into the core so that regenerating the shaders
keeps them.

Seven files conflicted. Three fork patches needed manual work although no conflict marker covered them
(details under "Fork-local work"). Every MLX regression gate is green and unchanged from `tag-20260928`:
LLM generate and tool-call (identical reports), mlx-audio 19/19, FLUX.2 image parity 55/55.

---

## Highlights

### On-device / iOS memory & stability
- **Text-only turns on VLMs no longer refill the whole conversation (#700).** FastVLM, Gemma 3,
  Gemma 4, Mistral 3 and SmolVLM paired every prompt with an all-ones attention mask, which disables
  prompt-cache reuse. The mask is now dropped when there is no image or video. The fork's own rule
  (only a *sparse* mask blocks reuse) already covered most of this; the upstream change removes the
  mask where it is created.
- **Qwen3.5 fused GDN projection is freed with the model (#631).** It was held as a trace constant
  and stayed resident after unload.
- **MLX errors on loader threads are now thrown (#698)** instead of reaching the default handler,
  which aborts the process. Covers the parallel file readers, the async `loadWeights` queue and
  on-demand components.
- **Exact prefix rewind in rotating KV caches (#622)**, plus a Gemma 3n cross-layer KV sharing fix.
- **KV cache memory is reported in `KVCacheStatus` (#639)**; **the reused cache prefix is reported
  before prefill (#644).** Not consumed by the app yet.

### New models
- **Qwen 3.8** text, MoE and VLM (`qwen3_8`, `qwen3_8_moe`, `qwen3_8_text`), with MTP speculative
  decoding (#545).
- **Mellum 2.1** (`mellum`, #697).
- **LFM2-VL configs written by transformers 5** (`intermediate_size`, `rope_parameters`, untied
  heads) load (#695); `LiquidAI/d1-3B` loads as LFM2-VL.
- EmbeddingGemma 2 (#684, `MLXEmbedders`, not linked by the app).

### New capabilities / API
- **Component-aware checkpoint loading (#679) and on-demand components (#580).** `loadWeights` now goes
  through `prepareComponents` → `loadModelCheckpoint` → `prepareCheckpoint` → `applyCheckpoint`;
  MuseGlimmer's vision encoder loads on first use.
- **Generation observability (#640)**: composable token-loop handlers (moved to
  `TokenLoopHandler.swift`) and deferred log probabilities.
- **`ChatSession.fork(history:)` (#641)** shares a prefix cache across conversations.
- **Streaming detokenizers from the tokenizer (#619)**, and held text is flushed at the end of
  generation (#670).
- **Named image attachments (#535)**; **`suppress_tokens` honored and multimodal placeholder tokens
  masked during sampling (#412).**
- **Compiled single-token decode for Qwen3.5 VLMs (#662)**; **reduced vocabulary projection during Qwen
  prefill (#614)** and hidden states split from the logit projection (#672).

### Correctness fixes
- **Qwen3.5 / Qwen3-Next gated delta net L2-norm eps was D times too large (#633)** (128x for the shipped
  head size). Outputs of Qwen3.5 models change slightly; the regression rows still pass.
- **Gemma tool calls keep nested object and array arguments (#626)** instead of raw strings.
- **Empty assistant text is omitted from content parts (#699)**, so Qwen3-VL renders tool calls correctly.
- **Tool parameter schema booleans stay Swift `Bool` (#653)**, not `0`/`1` in the prompt.
- **GLM-4-0414 markerless tool calls are parsed (#623)**; tool-call end-tag scan is chunk-local (#625).
- **Qwen reasoning history reconstruction (#663)**, **GLM4 MoE Lite quantized KV attention (#671)**,
  **NemotronH dense checkpoints (#635)**, **Qwen3.5 VLM checkpoints with MTP weights (#642)**,
  **WHT cross-SIMD sync (#650)**, **NVFP4 projections with global scale kept out of fusion (#705).**

### Build / toolchain
- **`mlx-swift` 0.32.3 / mlx-core v0.32.2** (see Dependency below). New API used by this range:
  `MLXLogger` (0.32.x). `Package.swift` swift-tools-version is 6.3.
- mlx-swift's CUDA build plugin (`Source/Encuda`) is behind `#if os(Linux)`, so the release tag is safe
  to build for iOS.

### Tests
- Scripted tokenizer and scripted models for tests (#680, #701); new integration suites for attachment
  labels, empty tool-call content, generation observability, Qwen reasoning templates and Qwen3.5
  checkpoints.

---

## Fork-local work this cycle

### Conflicts resolved (7 files)
- `Package.swift`: keep the local `../mlx-swift` path dependency; comment records the 0.32.3 requirement.
- `Chat.swift`: keep upstream's new `contentParts(for:layout:)` and the fork's logging `generate(messages:)`.
- `Evaluate.swift`: keep the fork's prefill trace logs around upstream's
  `evaluateTokenAndLogProbabilities`; take upstream's removal of the token-loop handlers.
- `Load.swift`: take upstream's component-aware loading; the fork's bits allow-list (incl. bits=1) now
  validates the merged `perLayerQuantization` before `prepareComponents`, so on-demand components are
  covered too. The error text now lists 1-bit.
- `TokenStreamDecoder.swift`: take upstream's `detokenizer.finish()`.
- `Gemma4.swift`: keep the fork's assistant + tool-response merge on upstream's
  `removingSpecialTokenLabels` input; keep the debug prompt log before upstream's text-only early return.
- `ToolTests.swift`: keep the fork's Gemma 4 tests and upstream's Gemma helpers.

### Fixed without a conflict marker
1. **`fallbackParser` re-threaded into `TokenLoopHandler.swift`.** Upstream (#640) moved
   `TextToolTokenLoopHandler` into a new file; the fork's init parameter stayed behind in the deleted
   block, and the two `generate` overloads that pass it would not have compiled.
2. **Native Gemma 4 tool calls go through upstream's parser.** The fork's `Gemma4FunctionParser` (kept
   for the double-brace JSON re-injection case) had its own scalar-only key:value loop, which hid #626.
   It now tries the JSON fallback and hands everything else to `GemmaFunctionParser` with Gemma 4 tags.
3. **Dependency move**, see below.

### Dependency reconciliation + PrismML
- `thirdparty/mlx` `prism-1bit-0.32.2` off `1f8e74e` (v0.32.2): the 3 PrismML commits cherry-picked;
  conflicts in `dequantize` (upstream float accumulation), the `dispatch_qmv` `qmv_quad` gate
  (`!global_scale` + `bits >= 2` at K=64 + `mode != "affine_sym"`) and a deleted CUDA test list. The
  bias-free `affine_sym_qmv_fast` / `affine_sym_qmv` kernels were added to `kernels/quantized.h`
  (ported from PrismML-Eng/mlx `4fc91df60`).
- `thirdparty/mlx-swift` `prism-1bit-0.32.3` off the 0.32.3 tag: gitlink → `7591f40`, `.gitmodules` url,
  `FMT_CONSTEVAL`, shaders regenerated (only the 4 quantized files changed), `QuantizationTests` carried
  over plus a new bias-free test.

---

## iOS / On-Device Impact Summary

| Area | Effect on iOS |
|------|---------------|
| Engine core | mlx-core 0.31.1 → v0.32.2, mlx-swift 0.31.4 → 0.32.3, PrismML patch re-applied |
| 1-bit / 2-bit models | Bonsai 1-bit, Ternary Bonsai 2-bit LLMs and the FLUX.2 Bonsai image models pass unchanged |
| VLM text turns | Prompt cache is reused on more models (#700) |
| Qwen3.5 | Slightly different outputs from the corrected GDN eps (#633); compiled VLM decode (#662) |
| Tool calls | Gemma nested arguments, schema booleans, empty assistant text, GLM-4-0414 |
| Loading | Loader-thread MLX errors throw instead of aborting (#698) |

---

## Risk Assessment — **4 identified risks** (2 medium, 2 low)

### R1 — The PrismML patch now sits on a new core (MEDIUM)
`dequantize`, `dispatch_qmv` and the bias-free kernels were re-derived by hand on v0.32.2.
*Verify:* done on macOS — `QuantizationTests` 11/11 (incl. the new bias-free test), LLM rows for
Bonsai 1-bit and three Ternary 2-bit models, FLUX.2 transformer parity 6.48e-3 relative RMS (was 6.5e-3)
and the end-to-end golden at mean 1.85 (was 2.20). Still open: one on-device render
(`testcases/imagegen/scripts/run_device_renders.sh binary 512`) for the iOS Metal path.

### R2 — No Swift test drives a scales-only checkpoint end to end (MEDIUM)
The `affine_sym` kernels are covered only by `testBiasFreeLowBitMatchesDerivedBias`. No catalogue
model uses scales-only weights today, so a break would surface only with a future PrismML export.
*Verify:* add a catalogue row when one ships.

### R3 — Qwen3.5 output shift from #633 (LOW)
Correct per the transformers reference, but long reasoning outputs can differ from last week's.
*Verify:* the regression rows pass; no action unless users report a change.

### R4 — Gemma 4 parser delegation (LOW)
Native Gemma 4 calls now take upstream's parser path. Bare scalars still decode as strings and
double-brace JSON is still handled by the fork. *Verify:* `ToolTests` 119/119 and the
`gemma-4-e2b-it-4bit` tool-call row pass.

---

## Follow-ups
1. One device render through the FLUX.2 harness (R1), and one MLX LLM chat on an iPhone.
2. `testcases/imagegen/fixtures/manifest.json` still points the checkpoint at the deleted
   `Bonsai-image-demo` path, so the heavy image suites skip silently; it was run here through a
   temporary link to `/Volumes/ssd2t/mlximages/bonsai-image-4B-binary-mlx`.
3. `testAnOutOfRangeCaptureLayerThrowsAtLoad` fails instead of skipping when the checkpoint is absent.
4. Push `thirdparty/mlx` `prism-1bit-0.32.2` to `wangqi/mlx` so the mlx-swift gitlink resolves on
   another machine.
