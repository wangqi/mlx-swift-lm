// Probe: does `ChatSession` reuse its prompt cache across turns, and does that differ between a
// HYBRID model (attention + recurrent layers, which cannot be rewound) and a DENSE one?
//
// Background. The app's `AIChatModelMLX` re-implements prompt-cache reuse and it has never
// engaged on Qwen3.5. Measured here across four runs:
//
//   run 3  stock library, Qwen3.5, 28.7k tokens: turn 2 = 20.1s vs a forced full prefill of
//          20.3s. No reuse at all -- the LIBRARY rebuilds too, so this was never only our bug.
//   run 4  after relaxing the all-ones attention-mask veto (ChatSession.swift, same commit as
//          this file): still 19.0s vs 19.0s. Necessary but not sufficient.
//   run 5  with the [KVDECIDE] diagnostic: `startsWith=false`, commonPrefix=28715 of cached
//          28721. The ledger and the re-render diverge by SIX tokens, at the assistant-turn
//          boundary -- Qwen3.5's template emits an empty `<think>\n\n</think>\n\n` block in the
//          generation prompt (chat_template.jinja:147-153) and omits it when re-rendering that
//          same message as history (:103). Append is therefore impossible, and rewinding to the
//          common prefix is blocked twice over: `trimmable=false` (MambaCache is not trimmable)
//          and `modelState=true` (per-call M-RoPE state cannot be rewound).
//
//   run 6  gemma-4-e2b (DENSE, LLM path, no mask at all): turn 1 = 8.785s / 27,916 tokens,
//          turn 2 = 0.306s / 18 tokens, turn 3 = 0.105s / 15 tokens, control = 7.985s.
//          `startsWith=true` -- Gemma's template IS append-stable, so `ExtendCachedPrefixRule`
//          fires. Note `trimmable=false` there too (rotating caches past a 512 window cannot
//          rewind): append, not rewind, is what carries every win measured here.
//   run 10 Qwen3-VL-4B (DENSE, VLM path, all-ones mask) A/B on one build -- see the note on
//          `denseQwen3VLReusesPromptCacheAcrossTurns` below. Reuse engages when the mask veto
//          is relaxed, and immediately crashes on a latent rank bug in the library's own
//          reduced-input construction.
//
//   run 11 AGENT SHAPE on Qwen3.5 (one user goal, then tool results only -- never a second user
//          message): `startsWith=TRUE`, appendSuffix on every turn. Turn 1 = 17.9s / 28,719
//          tokens, turns 2 and 3 = 0.110s / 0.118s prefilling 29 and 28 tokens, against a warm
//          full-prefill control of 20.8s. 189x. The six-token divergence in run 5 is a property
//          of the SECOND USER MESSAGE, which moves `ns.last_query_index` past the assistant turn
//          and sends its re-render down branch :103 instead of :101. The agent never sends one.
//   run 12 Qwen3-VL-4B after the rank-preserving reduced input landed alongside the mask
//          relaxation: reuse engages AND no longer crashes. 0.361s / 0.263s against a 129.1s
//          warm control (358x), answers correct. The `SmallVector out of range` abort of run 10
//          was the 1-D reduced input, now fixed in `ChatSession` itself.
//   run 13 Qwen3.5 PLAIN CHAT re-measured on the same build: still `startsWith=false`,
//          commonPrefix 28715 of 28721, rebuild on every turn, 19.7s against an 18.4s control.
//          Unchanged, and correctly so -- neither fix touches prompt rendering.
//   run 14 gemma-4-e2b re-measured: 0.071s / 0.092s against a 7.6s control. Unregressed.
//
// Conclusions carried out of this file:
//   * `startsWith` is the whole game. Both gemma-4 and Qwen3.5 have a non-trimmable cache at
//     28k tokens; the only difference is whether the template re-renders identically.
//   * Reuse on a hybrid must be pure append. Rewind is blocked twice (`trimmable=false`,
//     `modelState=true`) and no amount of policy tuning changes that.
//   * The mask relaxation is necessary for VLMs, insufficient alone, and harmful on its own --
//     it must ship with the rank-preserving reduced input or it converts a silent slowdown into
//     an uncatchable abort. Both landed together; runs 12 and 14 are the evidence.
//   * SHAPE, not topology, decides whether a hybrid can reuse. Qwen3.5 rebuilds in a chat and
//     appends in the agent, on the same weights and the same build. Nothing about MambaCache
//     needed to change; `startsWith` was always the whole game.
//
// WHAT MEASURES REUSE, and two things that do NOT (learned from run 1):
//   * `GenerateCompletionInfo.promptTokenCount` reports the FULL rendered transcript on this
//     path, not the reduced input, so it cannot distinguish reuse from rebuild. Printed only.
//   * Recalling turn 1's content proves nothing: `ChatSession` re-renders the whole transcript
//     every turn, so the model reads the fact out of the prompt either way. Kept as a
//     CORRUPTION check -- a cache spliced at the wrong offset yields fluent, wrong text.
// What does measure it: prefill TIME against `controlSession`, an independent session forced to
// do a full prefill of a comparable prompt, run last so the GPU is fully warm.
//
// Opt-in: set MLX_RUN_KVCACHE_PROBE=1. Never runs by accident; loads GBs of weights.
// wangqi modified 2026-08-24

import Foundation
import HuggingFace
import IntegrationTestHelpers
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
import Tokenizers

private let modelRoot =
    "~/Library/Mobile Documents/iCloud~com~acmeup~ai~ios~AIAssistant/Documents/models/mlx"

private struct TurnStats {
    let label: String
    let text: String
    let promptTokens: Int
    let generatedTokens: Int
    let promptTime: TimeInterval

    /// Rendered prompt tokens divided by prefill seconds. Meaningful only BETWEEN turns of the
    /// same size: a reused turn shows an absurd apparent rate precisely because it never
    /// processed the tokens the rate is computed from.
    var apparentPrefillRate: Double {
        promptTime > 0 ? Double(promptTokens) / promptTime : .infinity
    }
}

@Suite(
    .serialized,
    .timeLimit(.minutes(60)),
    .enabled(if: ProcessInfo.processInfo.environment["MLX_RUN_KVCACHE_PROBE"] == "1"))
struct KVCacheReuseProbeTests {

    /// ~28k tokens of system prompt, matching the 15k-24k the real agent run carried. Numbered
    /// so the text is not degenerately repetitive.
    private static let instructions: String = {
        (1...800).map { i in
            "Rule \(i): answer tersely, never explain yourself, and never add pleasantries. "
                + "This rule exists only to occupy prompt tokens for a prefill measurement."
        }.joined(separator: "\n")
    }()

    private static func turn(
        _ label: String, _ session: ChatSession, _ prompt: String
    ) async throws -> TurnStats {
        var text = ""
        var info: GenerateCompletionInfo?
        for try await generation in session.streamDetails(to: prompt) {
            if let chunk = generation.chunk { text += chunk }
            if let i = generation.info { info = i }
        }
        let completion = try #require(info, "stream ended without GenerateCompletionInfo")
        let stats = TurnStats(
            label: label,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: completion.promptTokenCount,
            generatedTokens: completion.generationTokenCount,
            promptTime: completion.promptTime)
        print(
            "[KVPROBE] \(label): promptTokens=\(stats.promptTokens) generated=\(stats.generatedTokens) "
                + "promptTime=\(String(format: "%.3f", stats.promptTime))s "
                + "apparentRate=\(String(format: "%.0f", stats.apparentPrefillRate))/s "
                + "text=\(stats.text.prefix(60).debugDescription)")
        return stats
    }

    /// Runs three conversational turns plus an independent full-prefill control, and reports
    /// whether reuse engaged. `expectReuse` is the claim under test, so a hybrid that does NOT
    /// reuse is recorded as the expected result rather than as a failure.
    /// A locally-materialised model directory, or `nil` when its weights are not on disk.
    /// Several entries under `modelRoot` are git stubs carrying only a `.git` folder.
    private static func localConfiguration(_ directory: String) -> ModelConfiguration? {
        let url = URL(
            fileURLWithPath: NSString(string: "\(modelRoot)/\(directory)").expandingTildeInPath)
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("config.json").path)
        else { return nil }
        return ModelConfiguration(directory: url)
    }

    private static func runProbe(
        configuration: ModelConfiguration, name: String, useVLMFactory: Bool, expectReuse: Bool
    ) async throws {
        let container: ModelContainer =
            useVLMFactory
            ? try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration)
            : try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration)

        // No maxKVSize / kvBits / kvScheme: any KV capacity re-throws on Qwen3.5-class hybrids,
        // and the app ships them nil for exactly this reason.
        func makeSession() -> ChatSession {
            ChatSession(
                container,
                instructions: instructions,
                generateParameters: .init(maxTokens: 48, temperature: 0.0, seed: 2025))
        }

        let session = makeSession()
        let t1 = try await turn(
            "\(name) turn 1 (cold prefill)", session,
            "My favourite colour is teal. Reply with exactly: OK")
        let t2 = try await turn(
            "\(name) turn 2 (candidate reuse)", session,
            "What is my favourite colour? One word.")
        let t3 = try await turn(
            "\(name) turn 3 (candidate reuse)", session, "Repeat that colour once more.")

        // Negative control: a fresh session, so its first turn MUST prefill everything. Run last,
        // when the GPU is fully warm -- run 1's only full-prefill sample was also its Metal
        // warm-up sample, which is exactly why it was unreadable.
        let control = try await turn(
            "\(name) control (forced full prefill)", makeSession(),
            "What is my favourite colour? One word.")

        // Guard the premise: at a small prompt the timing gap this test relies on would not
        // exist and a pass would mean nothing.
        #expect(
            t1.promptTokens > 10_000,
            "\(name): prompt was only \(t1.promptTokens) tokens - too small to be decisive")

        let reusedTurn2 = t2.promptTime < control.promptTime / 5
        let reusedTurn3 = t3.promptTime < control.promptTime / 5
        print(
            "[KVPROBE] \(name) VERDICT: reuse turn2=\(reusedTurn2) turn3=\(reusedTurn3) "
                + "(expected reuse=\(expectReuse))")

        #expect(
            reusedTurn2 == expectReuse,
            "\(name): turn 2 prefilled in \(String(format: "%.3f", t2.promptTime))s against a warm full prefill of \(String(format: "%.3f", control.promptTime))s")
        #expect(
            reusedTurn3 == expectReuse,
            "\(name): turn 3 prefilled in \(String(format: "%.3f", t3.promptTime))s against a warm full prefill of \(String(format: "%.3f", control.promptTime))s")

        // Corruption check (NOT a reuse signal). A cache spliced at the wrong position yields
        // fluent, wrong text rather than an error. Matters most when reuse DID engage.
        #expect(
            t2.text.lowercased().contains("teal"),
            "\(name): turn 2 answered \(t2.text.debugDescription) - cache may be positioned wrongly")
        #expect(
            t3.text.lowercased().contains("teal"),
            "\(name): turn 3 answered \(t3.text.debugDescription) - cache may be positioned wrongly")
    }

    /// Dense model: rewind is available, so the template's six-token divergence should cost six
    /// tokens rather than the whole prompt. This is the claim under test.
    @Test func denseGemma4ReusesPromptCacheAcrossTurns() async throws {
        let configuration = try #require(
            Self.localConfiguration("gemma-4-e2b-it-4bit"), "gemma-4-e2b weights not on disk")
        try await Self.runProbe(
            configuration: configuration, name: "gemma-4-e2b",
            useVLMFactory: false, expectReuse: true)
    }

    /// The case that actually tests the attention-mask relaxation in `ChatSession.swift`:
    /// a DENSE model on the VLM path. `Qwen3VL.prepare` attaches an all-ones int8 mask
    /// unconditionally on its text-only branch (:121-124), and Qwen3-VL has no recurrent layers,
    /// so the mask is the only thing that can block reuse.
    ///
    /// gemma-4 above does NOT test this: it loads through `LLMModelFactory`, whose `LMInput`
    /// carries no mask at all, so it reuses with or without the fix.
    ///
    /// Run with `MLX_STRICT_MASK_VETO=1` to restore the pre-fix veto and confirm the same model
    /// rebuilds -- that A/B is what makes the fix attributable rather than merely correlated.
    /// Downloads ~2.3 GB from the Hub on first run, into `~/.cache/huggingface/`.
    @Test func denseQwen3VLReusesPromptCacheAcrossTurns() async throws {
        // NOT loaded by Hub id. `mlx-community/Qwen3-VL-4B-Instruct-4bit` ships a single
        // `model.safetensors` alongside a stale `model.safetensors.index.json` whose weight_map
        // still names `model-000{01,02}-of-00002.safetensors`, so the loader fails with
        // "[load_safetensors] Failed to open file ... model-00001-of-00002.safetensors" AFTER a
        // 46-minute download. `MLX_QWEN3VL_DIR` points at a directory of symlinks into the Hub
        // snapshot with that index omitted, which makes the loader read the single file.
        let path = try #require(
            ProcessInfo.processInfo.environment["MLX_QWEN3VL_DIR"],
            "set MLX_QWEN3VL_DIR to a Qwen3-VL directory whose stale index has been removed")
        let url = URL(fileURLWithPath: path)
        try #require(
            FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path),
            "no config.json at \(path)")
        // `expectReuse: true` since the mask relaxation and the rank-preserving reduced input
        // landed TOGETHER in `ChatSession.swift`. The history is worth keeping because it is the
        // reason they cannot be split:
        //
        //   veto strict                  -> rebuild every turn, 116s / 113s / 119s vs a 121s
        //                                   control. No crash, answers correct, no reuse.
        //   veto relaxed, 1-D reduced    -> startsWith=true, appendSuffix(27918), then
        //                                   "Fatal error: SmallVector out of range"
        //                                   (mlx/c/array.cpp:335) -- an uncatchable abort.
        //   veto relaxed, rank preserved -> 0.361s / 0.263s vs a 129.1s control, "Teal" both
        //                                   turns. This is what the tree now does.
        //
        // The mask veto was accidentally shielding every VLM from a latent rank bug in the
        // library's own reduced-input construction: it built `LMInput(tokens: MLXArray(Array(...)))`,
        // always 1-D, while `Qwen3VL.prepare` produces `[1, N]` and `getRopeIndex` opens with
        // `inputIds.dim(1)`. This test is the guard on that pairing -- if it aborts rather than
        // fails, the rank fix has been reverted and the mask fix has not.
        try await Self.runProbe(
            configuration: ModelConfiguration(directory: url),
            name: "qwen3-vl-4b", useVLMFactory: true, expectReuse: true)
    }

    /// A0: does the AGENT's message shape render append-stably on a hybrid, where a plain chat's
    /// does not?
    ///
    /// The four cases above all measure a plain chat -- user / assistant / user / assistant. There
    /// Qwen3.5's template diverges by six tokens at the assistant boundary: the generation prompt
    /// emits an empty `<think>\n\n</think>\n\n` block (chat_template.jinja:147-153) which the
    /// re-render of that same message as history omits (:103), because a second USER message moved
    /// `ns.last_query_index` past it.
    ///
    /// The agent never sends a second user message. It sends one user goal, then alternates
    /// assistant-with-tool-call / tool-result forever, so every assistant turn stays AFTER
    /// `last_query_index` and takes branch :101 instead. With think tags already stripped before
    /// they reach the transcript, `reasoning_content` is empty and that branch renders
    /// `<|im_start|>assistant\n<think>\n\n</think>\n\n` + content -- byte-identical to the
    /// generation prompt plus the content. If that holds, the agent's prompt is already
    /// append-stable and no prompt-construction change is needed.
    ///
    /// Read `startsWith` from the `[KVDECIDE]` lines, not just the verdict: the timing check is the
    /// consequence, `startsWith` is the cause.
    @Test func hybridQwen35ReusesAcrossAgentShapedToolTurns() async throws {
        let configuration = try #require(
            Self.localConfiguration("Qwen3.5-2B-MLX-8bit"), "Qwen3.5-2B weights not on disk")
        try await Self.runAgentShapedProbe(
            configuration: configuration, name: "qwen3.5-2b-agentshape", useVLMFactory: true)
    }

    /// Same as `runProbe`, but continues the session with TOOL results rather than user messages,
    /// which is the only structural difference between the agent and a chat.
    private static func runAgentShapedProbe(
        configuration: ModelConfiguration, name: String, useVLMFactory: Bool
    ) async throws {
        let container: ModelContainer =
            useVLMFactory
            ? try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration)
            : try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration)

        func makeSession() -> ChatSession {
            ChatSession(
                container,
                instructions: instructions,
                generateParameters: .init(maxTokens: 48, temperature: 0.0, seed: 2025))
        }

        func turnWithMessages(
            _ label: String, _ session: ChatSession, _ messages: [Chat.Message]
        ) async throws -> TurnStats {
            var text = ""
            var info: GenerateCompletionInfo?
            for try await generation in session.streamDetails(to: messages) {
                if let chunk = generation.chunk { text += chunk }
                if let i = generation.info { info = i }
            }
            let completion = try #require(info, "stream ended without GenerateCompletionInfo")
            let stats = TurnStats(
                label: label, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                promptTokens: completion.promptTokenCount,
                generatedTokens: completion.generationTokenCount,
                promptTime: completion.promptTime)
            print(
                "[KVPROBE] \(label): promptTokens=\(stats.promptTokens) generated=\(stats.generatedTokens) "
                    + "promptTime=\(String(format: "%.3f", stats.promptTime))s "
                    + "text=\(stats.text.prefix(60).debugDescription)")
            return stats
        }

        let session = makeSession()
        // One user goal, exactly as the agent sends it.
        let t1 = try await turn(
            "\(name) turn 1 (cold prefill, user goal)", session,
            "My favourite colour is teal. Reply with exactly: OK")
        // Then tool results only -- never another user message.
        let t2 = try await turnWithMessages(
            "\(name) turn 2 (tool result)", session,
            [.tool("{\"success\":true,\"message\":\"wrote fibonacci.py\"}", id: "call_1")])
        let t3 = try await turnWithMessages(
            "\(name) turn 3 (tool result)", session,
            [.tool("{\"success\":true,\"message\":\"ran fibonacci.py\"}", id: "call_2")])

        // Negative control: a fresh session, so its first turn MUST prefill everything. It is fed
        // the user goal AND the tool result as one batch -- a session whose first message is a tool
        // result cannot be rendered at all ("No user query found in messages"), which is itself a
        // reminder that the agent shape is only ever reached by CONTINUING a session.
        let control = try await turnWithMessages(
            "\(name) control (forced full prefill)", makeSession(),
            [
                .user("My favourite colour is teal. Reply with exactly: OK"),
                .tool("{\"success\":true,\"message\":\"wrote fibonacci.py\"}", id: "call_1"),
            ])

        #expect(
            t1.promptTokens > 10_000,
            "\(name): prompt was only \(t1.promptTokens) tokens - too small to be decisive")

        let reusedTurn2 = t2.promptTime < control.promptTime / 5
        let reusedTurn3 = t3.promptTime < control.promptTime / 5
        print(
            "[KVPROBE] \(name) VERDICT: reuse turn2=\(reusedTurn2) turn3=\(reusedTurn3)")
        #expect(
            reusedTurn2,
            "\(name): turn 2 prefilled in \(String(format: "%.3f", t2.promptTime))s against a warm full prefill of \(String(format: "%.3f", control.promptTime))s")
        #expect(
            reusedTurn3,
            "\(name): turn 3 prefilled in \(String(format: "%.3f", t3.promptTime))s against a warm full prefill of \(String(format: "%.3f", control.promptTime))s")
    }

    /// Hybrid model in a PLAIN CHAT: still does not reuse, and that is correct rather than a
    /// gap. Re-measured on the build carrying both fixes (run 13): `startsWith=false`,
    /// commonPrefix 28715 of 28721, 19.7s against an 18.4s control.
    ///
    /// The six missing tokens are Qwen3.5's empty `<think>\n\n</think>\n\n` block, emitted in
    /// the generation prompt (chat_template.jinja:147-153) and omitted when that same assistant
    /// message is re-rendered as history (:103). What sends it down :103 is the SECOND USER
    /// MESSAGE moving `ns.last_query_index` past it -- so this is a property of the chat shape,
    /// not of the model, the cache topology or anything either fix touches.
    ///
    /// `hybridQwen35ReusesAcrossAgentShapedToolTurns` is the same weights and the same build with
    /// no second user message, and it appends. Keeping both cases is the point: together they
    /// pin that SHAPE decides reuse here. Only append-only prompt construction would flip this
    /// one, and the agent -- the thing that pays for prefill -- does not need it.
    /// wangqi modified 2026-08-24
    @Test func hybridQwen35DoesNotReusePromptCacheYet() async throws {
        let configuration = try #require(
            Self.localConfiguration("Qwen3.5-2B-MLX-8bit"), "Qwen3.5-2B weights not on disk")
        try await Self.runProbe(
            configuration: configuration, name: "qwen3.5-2b",
            useVLMFactory: true, expectReuse: false)
    }
}
