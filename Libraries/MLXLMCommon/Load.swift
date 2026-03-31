// Copyright © 2024 Apple Inc.

import Foundation
import Hub
import MLX
import MLXNN
import Tokenizers

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

/// Download the model using the `HubApi`.
///
/// This will download `*.safetensors` and `*.json` if the ``ModelConfiguration``
/// represents a Hub id, e.g. `mlx-community/gemma-2-2b-it-4bit`.
///
/// This is typically called via ``ModelFactory/load(hub:configuration:progressHandler:)``
///
/// - Parameters:
///   - hub: HubApi instance
///   - configuration: the model identifier
///   - progressHandler: callback for progress
/// - Returns: URL for the directory containing downloaded files
public func downloadModel(
    hub: HubApi, configuration: ModelConfiguration,
    progressHandler: @Sendable @escaping (Progress) -> Void
) async throws -> URL {
    do {
        switch configuration.id {
        case .id(let id, let revision):
            // download the model weights
            let repo = Hub.Repo(id: id)
            let modelFiles = ["*.safetensors", "*.json", "*.jinja"]
            return try await hub.snapshot(
                from: repo,
                revision: revision,
                matching: modelFiles,
                progressHandler: progressHandler
            )
        case .directory(let directory):
            return directory
        }

    } catch Hub.HubClientError.authorizationRequired {
        // an authorizationRequired means (typically) that the named repo doesn't exist on
        // on the server so retry with local only configuration
        return configuration.modelDirectory(hub: hub)

    } catch {
        let nserror = error as NSError
        if nserror.domain == NSURLErrorDomain && nserror.code == NSURLErrorNotConnectedToInternet {
            // Error Domain=NSURLErrorDomain Code=-1009 "The Internet connection appears to be offline."
            // fall back to the local directory
            return configuration.modelDirectory(hub: hub)
        } else {
            throw error
        }
    }
}

/// Load model weights.
///
/// This is typically called via ``ModelFactory/load(hub:configuration:progressHandler:)``.
/// This function loads all `safetensor` files in the given `modelDirectory`,
/// calls ``LanguageModel/sanitize(weights:metadata:)`` to allow per-model preprocessing,
/// applies optional quantization, and
/// updates the model with the weights.
public func loadWeights(
    modelDirectory: URL, model: LanguageModel,
    quantization: BaseConfiguration.Quantization? = nil,
    perLayerQuantization: BaseConfiguration.PerLayerQuantization? = nil
) throws {
    // load the weights and collect metadata from the first safetensor file
    var weights = [String: MLXArray]()
    var metadata = [String: String]()
    // Guard against nil enumerator (missing or inaccessible model directory).
    // wangqi modified 2026-03-31
    guard let enumerator = FileManager.default.enumerator(
        at: modelDirectory, includingPropertiesForKeys: nil)
    else {
        throw ModelLoadError.directoryNotAccessible(modelDirectory)
    }
    for case let url as URL in enumerator {
        if url.pathExtension == "safetensors" {
            let (w, m) = try loadArraysAndMetadata(url: url)
            for (key, value) in w {
                weights[key] = value
            }
            if metadata.isEmpty {
                metadata = m
            }
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
