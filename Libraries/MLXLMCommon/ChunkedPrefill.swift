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

/// Chunked prefill helper shared by all VLM models on iOS. Caller has already
/// done vision-feature extraction. This function feeds the (text- or
/// embedding-) sequence to the model in windowSize-sized slices, then runs one
/// final pass over the residue so vision embeddings in `[fed..<totalLen]` are
/// still seen by the model. Returns `.logits(LMOutput)` from that final pass.
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
    windowSize: Int?,
    feedChunk: VLMChunkFeed
) -> PrepareResult {
    let prefillStepSize = windowSize ?? 512
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
        "[chunkedVLMPrefill] total=\(totalLen) step=\(prefillStepSize) idsNDim=\(inputIds.ndim) hasEmbeds=\(inputEmbeddings != nil) hasDeepstack=\(deepstackEmbeds != nil)"
    )

    var fed = 0
    while totalLen - fed > prefillStepSize {
        let end = fed + prefillStepSize

        // Always slice inputIds alongside any embeddings so per-chunk position
        // derivation in the model (when it uses inputIds for shape / RoPE) is
        // consistent with the embedding chunk.
        let idsChunk: MLXArray = inputIdsIs2D ? inputIds[0..., fed ..< end] : inputIds[fed ..< end]
        let embChunk: MLXArray? = inputEmbeddings.map { $0[0..., fed ..< end, 0...] }
        let maskChunk: MLXArray? = visualMask.map { $0[0..., fed ..< end] }

        let deepstackChunk: [MLXArray]? = deepstackEmbeds.map { all in
            let sDS = fed == 0 ? 0 : visualCumulative[fed - 1]
            let eDS = visualCumulative[end - 1]
            return all.map { $0[sDS ..< eDS, 0...] }
        }

        _ = feedChunk(idsChunk, embChunk, maskChunk, deepstackChunk)
        asyncEval(cache)
        fed = end
    }

    // Final pass over residue [fed ..< totalLen] (or full prompt if loop never
    // ran). Vision embeddings in the residue are seen here — this is the fix
    // for the image-blind regression. Result is the sampler-ready logits.
    let idsTail: MLXArray = inputIdsIs2D ? inputIds[0..., fed ..< totalLen] : inputIds[fed ..< totalLen]
    let embTail: MLXArray? = inputEmbeddings.map { $0[0..., fed ..< totalLen, 0...] }
    let maskTail: MLXArray? = visualMask.map { $0[0..., fed ..< totalLen] }
    let deepstackTail: [MLXArray]? = deepstackEmbeds.map { all in
        let sDS = fed == 0 ? 0 : visualCumulative[fed - 1]
        let eDS = visualCumulative[totalLen - 1]
        return all.map { $0[sDS ..< eDS, 0...] }
    }

    let finalOutput = feedChunk(idsTail, embTail, maskTail, deepstackTail)
    eval(cache)
    return .logits(finalOutput)
}
