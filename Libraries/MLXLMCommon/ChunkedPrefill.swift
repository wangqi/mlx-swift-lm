// Chunked prefill helper for VLM models on iOS / Mac Catalyst.
// Mirrors the LLM chunked prefill (LLMModel.swift) so VLM prepare() does not
// produce a [1, n_heads, N, N] attention activation for large N (Metal abort).
// wangqi added 2026-05-15
// Reshape: closure returns LMOutput and helper returns PrepareResult.logits,
// so vision embeddings in the residue chunk are still fed through the model's
// own languageModel(...) (not the text-only callAsFunction) and the sampler
// receives logits directly — wangqi modified 2026-05-16

import Foundation
import MLX

/// Per-chunk closure the VLM model provides to feed a slice through its own
/// `languageModel`. The closure must return the model's `LMOutput`; the helper
/// uses the final-chunk return value as the sampler-ready logits and discards
/// the intermediate returns.
///
/// `idsChunk` matches the rank of the original `inputIds` (2D `[1, step]` if
/// the VLM processor emitted 2D tokens, 1D `[step]` otherwise) so the model's
/// `languageModel(...)` is called with the same shape contract as the
/// single-shot path.
public typealias VLMChunkFeed = (
    _ idsChunk: MLXArray?,
    _ embeddingsChunk: MLXArray?,
    _ visualMaskChunk: MLXArray?,
    _ deepstackChunk: [MLXArray]?
) -> LMOutput

/// Chunked prefill helper for the VLM models upstream still prefills in a single
/// forward. Caller has already done vision-feature extraction. This function feeds
/// the (text- or embedding-) sequence to the model in `prefill`-sized slices, then
/// runs one final pass over the residue so vision embeddings in the tail are still
/// seen by the model. Returns `.logits(LMOutput)` from that final pass.
///
/// Most VLMs no longer need this: upstream's `PrefillParameters.forEachChunk` chunks
/// their prefill natively on every platform. Only models whose `prepare` is still
/// single-shot upstream, and that carry vision state the generic driver cannot slice
/// (`visualMask` / `deepstackEmbeds`), route through here — wangqi modified 2026-08-10.
///
/// Shape contracts:
/// - `inputIds`: typically 2D `[1, seq]` from VLM processors (`.expandedDimensions(axis: 0)`).
///   1D `[seq]` is also accepted for LLM-style callers.
/// - `inputEmbeddings`: when non-nil, shape `[1, seq, dim]`; drives chunk length.
/// - `visualMask`: shape `[1, seq]`; required when `deepstackEmbeds` is set.
/// - `deepstackEmbeds`: list of `[numVisualTokens, dim]` arrays (Qwen3VL only).
public func chunkedVLMPrefill(
    inputIds: MLXArray,
    inputEmbeddings: MLXArray?,
    visualMask: MLXArray?,
    deepstackEmbeds: [MLXArray]?,
    cache: [any KVCache],
    prefill: PrefillParameters,
    feedChunk: VLMChunkFeed
) throws -> PrepareResult {
    let inputIdsIs2D = inputIds.ndim == 2
    let totalLen: Int = {
        if let inputEmbeddings { return inputEmbeddings.dim(1) }
        return inputIdsIs2D ? inputIds.dim(1) : inputIds.dim(0)
    }()

    // Pre-compute cumulative vision-token count for deepstack slicing.
    // Forces ONE sync on visualMask up front; chunk loop is then sync-free.
    var visualCumulative: [Int] = []
    if let visualMask, deepstackEmbeds != nil {
        let bools = visualMask[0, 0...].asArray(Bool.self)
        visualCumulative.reserveCapacity(bools.count)
        var running = 0
        for b in bools {
            running += b ? 1 : 0
            visualCumulative.append(running)
        }
    }

    MLXLogCollector.shared.log(
        "[chunkedVLMPrefill] total=\(totalLen) step=\(prefill.resolvedStepSize()) chunking=\(prefill.chunking) idsNDim=\(inputIds.ndim) hasEmbeds=\(inputEmbeddings != nil) hasDeepstack=\(deepstackEmbeds != nil)"
    )

    // Slices one [start ..< end] window out of every parallel input the model
    // needs. inputIds is always sliced alongside any embeddings so per-chunk
    // position derivation in the model (when it uses inputIds for shape / RoPE)
    // is consistent with the embedding chunk.
    func slice(_ range: Range<Int>) -> (MLXArray, MLXArray?, MLXArray?, [MLXArray]?) {
        let ids: MLXArray = inputIdsIs2D ? inputIds[0..., range] : inputIds[range]
        let embeds: MLXArray? = inputEmbeddings.map { $0[0..., range, 0...] }
        let mask: MLXArray? = visualMask.map { $0[0..., range] }
        let deepstack: [MLXArray]? = deepstackEmbeds.map { all in
            let sDS = range.lowerBound == 0 ? 0 : visualCumulative[range.lowerBound - 1]
            let eDS = visualCumulative[range.upperBound - 1]
            return all.map { $0[sDS ..< eDS, 0...] }
        }
        return (ids, embeds, mask, deepstack)
    }

    // Delegate the loop to upstream's prefill driver — wangqi modified 2026-08-10.
    // It owns cooperative cancellation between chunks, a per-chunk autorelease pool
    // and the per-chunk progress report, none of which the fork's own while-loop had.
    // What stays fork-local is the lockstep slicing above (visualMask + deepstack) and
    // the vision-aware residue pass below.
    //
    // A prompt that already fits in one window is deliberately NOT handed to the driver.
    // This patch exists to bound the attention activation for large N; at N <= window
    // there is nothing to bound, and the driver's `reserving: 1` contract would split the
    // prompt into a chunk plus a 1-token pass. That would change the common case (a short
    // image query) from one forward to two, and would feed the tail token through the
    // model separately from the vision embeddings it sits next to. Short prompts keep the
    // exact single-forward behavior they had before the tag-20260810 merge.
    var processed = 0
    if totalLen > prefill.resolvedStepSize() {
        processed = try prefill.forEachChunk(total: totalLen) { range in
            let (idsChunk, embChunk, maskChunk, deepstackChunk) = slice(range)
            _ = feedChunk(idsChunk, embChunk, maskChunk, deepstackChunk)
            asyncEval(cache)
        }
        if processed > 0 {
            eval(cache)
        }
    }

    // Final pass over the residue [processed ..< totalLen] (or the whole prompt when
    // no chunking happened). Vision embeddings in the residue are seen here — this is
    // the fix for the image-blind regression. Result is the sampler-ready logits.
    let (idsTail, embTail, maskTail, deepstackTail) = slice(processed ..< totalLen)
    let finalOutput = feedChunk(idsTail, embTail, maskTail, deepstackTail)
    prefill.progress?(totalLen, totalLen)
    return .logits(finalOutput)
}
