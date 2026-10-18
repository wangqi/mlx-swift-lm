// Copyright © 2026 Apple Inc.

import Foundation

// MiniCPM5 had no format of its own: its Llama architecture with a 130K vocabulary resolved to
// `.llama3`, whose inline-JSON parser never read this syntax, so every call was lost.
// wangqi modified 2026-10-18

/// Parser for MiniCPM5: `<function name="f"><param name="k">v</param></function>`.
///
/// The template asks for multi-line values inside `<![CDATA[...]]>`, which is unwrapped.
public struct MiniCPM5FunctionParser: ToolCallParser, Sendable {
    public let startTag: String? = "<function name="
    public let endTag: String? = "</function>"

    public init() {}

    public func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // `parseEOS` splits on the start tag, so the content may begin at the name itself.
        if let start = text.range(of: "<function name=") {
            text = String(text[start.upperBound...])
        }
        if let end = text.range(of: "</function>") {
            text = String(text[..<end.lowerBound])
        }

        guard let nameEnd = text.firstIndex(of: ">") else { return nil }
        let funcName = extractName(String(text[..<nameEnd]))
        guard !funcName.isEmpty else { return nil }

        let paramConfig = getParameterConfig(funcName: funcName, tools: tools)
        var arguments: [String: any Sendable] = [:]
        let body = String(text[text.index(after: nameEnd)...])

        var searchRange = body.startIndex ..< body.endIndex
        while let paramStart = body.range(of: "<param name=", range: searchRange) {
            guard
                let nameClose = body.range(
                    of: ">", range: paramStart.upperBound ..< body.endIndex)
            else { break }
            let paramName = extractName(
                String(body[paramStart.upperBound ..< nameClose.lowerBound]))
            // A value cut off by the token limit keeps what arrived.
            let paramEnd = body.range(of: "</param>", range: nameClose.upperBound ..< body.endIndex)
            var value = String(
                body[nameClose.upperBound ..< (paramEnd?.lowerBound ?? body.endIndex)])
            value = Self.unwrapCDATA(value.trimmingCharacters(in: .whitespacesAndNewlines))

            if !paramName.isEmpty {
                let paramSchema = paramConfig[paramName] as? [String: any Sendable]
                arguments[paramName] =
                    ToolArgumentNormalization.normalize(.string(value), schema: paramSchema)
                    .sendableValue
            }
            guard let paramEnd else { break }
            searchRange = paramEnd.upperBound ..< body.endIndex
        }

        return ToolCall(function: .init(name: funcName, arguments: arguments))
    }

    private static func unwrapCDATA(_ value: String) -> String {
        guard value.hasPrefix("<![CDATA["), value.hasSuffix("]]>") else { return value }
        return String(value.dropFirst("<![CDATA[".count).dropLast("]]>".count))
    }
}
