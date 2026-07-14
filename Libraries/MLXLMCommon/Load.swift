// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN
// Thrown when a model uses a quantization bit-depth not supported by the current MLX version.
// wangqi modified 2026-03-31
struct QuantizationBitsError: LocalizedError {
    let bits: Int
    var errorDescription: String? {
        "[quantize] The requested number of bits \(bits) is not supported. The supported bits are 2, 3, 4, 5, 6 and 8."
    }
}

// Thrown when the model directory cannot be enumerated (missing, deleted, or permission denied).
// wangqi modified 2026-03-31
enum ModelLoadError: LocalizedError {
    case directoryNotAccessible(URL)
    var errorDescription: String? {
        switch self {
        case .directoryNotAccessible(let url):
            return "Model directory is not accessible: \(url.path)"
        }
    }
}

private struct SafetensorsIndex: Decodable {
    let weightMap: [String: String]

    enum CodingKeys: String, CodingKey {
        case weightMap = "weight_map"
    }
}

package func safetensorWeightURLs(in modelDirectory: URL) throws -> [URL] {
    let indexURL = modelDirectory.appendingPathComponent("model.safetensors.index.json")
    if FileManager.default.fileExists(atPath: indexURL.path) {
        let data = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
        return Set(index.weightMap.values)
            .sorted()
            .map { modelDirectory.appendingPathComponent($0) }
    }

    // Guard against nil enumerator (missing or inaccessible model directory)
    // instead of force-unwrapping. Preserved across the PR #408 refactor that
    // moved enumeration into this helper.
    // wangqi modified 2026-07-14
    guard let enumerator = FileManager.default.enumerator(
        at: modelDirectory, includingPropertiesForKeys: nil)
    else {
        throw ModelLoadError.directoryNotAccessible(modelDirectory)
    }
    return enumerator.compactMap { item -> URL? in
        guard let url = item as? URL, url.pathExtension == "safetensors" else {
            return nil
        }
        return url
    }
}

/// Load model weights.
///
/// This is typically called via ``GenericModelFactory/load(from:using:configuration:useLatest:progressHandler:)``.
/// This function loads model weight `safetensor` files in the given `modelDirectory`,
/// calls ``BaseLanguageModel/sanitize(weights:metadata:)`` to allow per-model preprocessing,
/// applies optional quantization, and
/// updates the model with the weights.
public func loadWeights(
    modelDirectory: URL, model: BaseLanguageModel,
    quantization: BaseConfiguration.Quantization? = nil,
    perLayerQuantization: BaseConfiguration.PerLayerQuantization? = nil
) throws {
    // load the weights and collect metadata from the first safetensor file
    var weights = [String: MLXArray]()
    var metadata = [String: String]()
    for url in try safetensorWeightURLs(in: modelDirectory) {
        let (w, m) = try loadArraysAndMetadata(url: url)
        for (key, value) in w {
            weights[key] = value
        }
        if metadata.isEmpty {
            metadata = m
        }
    }

    // per-model cleanup (models can inspect metadata to customize behavior)
    weights = model.sanitize(weights: weights, metadata: metadata)

    // quantize if needed
    if quantization != nil || perLayerQuantization != nil {
        // Validate bits before quantizing to avoid a fatal error from the MLX C++ layer.
        // Supported bits are 2, 3, 4, 5, 6 and 8.
        // wangqi modified 2026-03-31
        let supportedBits: Set<Int> = [2, 3, 4, 5, 6, 8]
        var bitsToCheck: [Int] = []
        if let q = quantization { bitsToCheck.append(q.bits) }
        if let plq = perLayerQuantization {
            if let defaultQ = plq.quantization { bitsToCheck.append(defaultQ.bits) }
            for case .quantize(let q) in plq.perLayerQuantization.values { bitsToCheck.append(q.bits) }
        }
        if let unsupportedBits = bitsToCheck.first(where: { !supportedBits.contains($0) }) {
            throw QuantizationBitsError(bits: unsupportedBits)
        }

        quantize(model: model) { path, module in
            if weights["\(path).scales"] != nil {
                if let perLayerQuantization {
                    return perLayerQuantization.quantization(layer: path)?.asTuple
                } else {
                    return quantization?.asTuple
                }
            } else {
                return nil
            }
        }
    }

    // apply the loaded weights
    let parameters = ModuleParameters.unflattened(weights)
    try model.update(parameters: parameters, verify: [.all])

    eval(model)
}
