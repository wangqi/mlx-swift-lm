// Copyright © 2025 Apple Inc.
// Add Gemma 4 tool call parser for <|tool_call>call:name{...}<tool_call|> format
// wangqi modified 2026-04-13

import Foundation

/// Parser for Gemma 4 format: call:name{key:value,k:<|"|>str<|"|>}
/// Gemma 4 uses <|tool_call> / <tool_call|> tags (not <start_function_call> / <end_function_call>)
/// and <|"|> as the string escape delimiter (not <escape>).
/// Reference: https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/tool_parsers/function_gemma.py
public struct Gemma4FunctionParser: ToolCallParser, Sendable {
    public let startTag: String? = "<|tool_call>"
    public let endTag: String? = "<tool_call|>"

    private let escapeMarker = "<|\"|>"

    private var nativeParser: GemmaFunctionParser {
        GemmaFunctionParser(startTag: "<|tool_call>", endTag: "<tool_call|>", escapeMarker: escapeMarker)
    }

    public init() {}

    public func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        // Strip tags if present
        var text = content
        if let start = startTag {
            text = text.replacingOccurrences(of: start, with: "")
        }
        if let end = endTag {
            text = text.replacingOccurrences(of: end, with: "")
        }

        // Pattern: call:(\w+)\{(.*?)\}
        // Find "call:" followed by function name and arguments in braces
        guard let callRange = text.range(of: "call:") else { return nil }

        let remaining = String(text[callRange.upperBound...])

        // Extract function name (word characters until {)
        guard let braceStart = remaining.firstIndex(of: "{") else { return nil }
        let funcName = String(remaining[..<braceStart])

        guard !funcName.isEmpty else { return nil }

        // Extract arguments string (everything between { and })
        guard let braceEnd = remaining.lastIndex(of: "}") else { return nil }
        var argsStr = String(remaining[remaining.index(after: braceStart) ..< braceEnd])

        // Try JSON parsing first.
        // The Gemma 4 Jinja chat template wraps re-injected arguments with an extra pair of
        // braces (e.g. {{{ tool_call['function']['arguments'] }}}), so on the second+ call the
        // model produces double braces: call:get_date{{"offset":"0"}} instead of the native
        // call:get_date{offset:0}. In that case argsStr = {"offset":"0"} which is a JSON object.
        // We also handle the single-brace JSON case ("offset":"0") as a best-effort.
        // wangqi modified 2026-04-13
        if !argsStr.isEmpty {
            let jsonCandidates = [argsStr, "{\(argsStr)}"]
            for candidate in jsonCandidates {
                if let data = candidate.data(using: .utf8),
                    let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                {
                    let arguments: [String: any Sendable] = dict.mapValues { asSendable($0) }
                    return ToolCall(function: .init(name: funcName, arguments: arguments))
                }
            }
        }

        // Native key:value syntax goes to upstream's parameterized parser, which reads nested
        // objects and arrays against the tool schema (#626). The fork's own scalar-only loop
        // turned those into raw strings. wangqi modified 2026-10-17
        return nativeParser.parse(content: content, tools: tools)
    }
}
