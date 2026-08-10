// Copyright © 2025 Apple Inc.

import Foundation

/// Parser for Pythonic tool call format: [function_name(arg1='value1', arg2='value2')]
/// Used by LFM2.5 and similar models that output tool calls in Python function call syntax.
/// Reference: LiquidAI LFM2.5 chat template format
public struct PythonicToolCallParser: ToolCallParser, Sendable {
    public let startTag: String?
    public let endTag: String?

    public init(startTag: String? = nil, endTag: String? = nil) {
        self.startTag = startTag
        self.endTag = endTag
    }

    public func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        var text = content

        // Strip tags if present
        if let start = startTag, let startRange = text.range(of: start) {
            text = String(text[startRange.upperBound...])
        }
        if let end = endTag, let endRange = text.range(of: end) {
            text = String(text[..<endRange.lowerBound])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let funcName: String
        let argsString: String

        // Required brackets pattern (matches Python reference: r"\[(\w+)\((.*?)\)\]")
        // The required \] forces .*? to backtrack past nested ) inside argument values.
        let bracketPattern = #"\[(\w+)\((.*?)\)\]"#
        if let regex = try? NSRegularExpression(
            pattern: bracketPattern, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(
                in: text, options: [], range: NSRange(text.startIndex..., in: text)),
            let nameRange = Range(match.range(at: 1), in: text),
            let argsRange = Range(match.range(at: 2), in: text)
        {
            funcName = String(text[nameRange])
            argsString = String(text[argsRange])
        } else {
            // Fallback for without-brackets case: use string indices to find the
            // outermost parentheses, avoiding the greedy/non-greedy regex pitfall.
            if let openParen = text.firstIndex(of: "("),
               let closeParen = text.lastIndex(of: ")")
            {
                let name = text[text.startIndex ..< openParen]
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    funcName = String(name)
                    argsString = String(text[text.index(after: openParen) ..< closeParen])
                    let arguments = parseArguments(argsString, funcName: funcName, tools: tools)
                    return ToolCall(function: .init(name: funcName, arguments: arguments))
                }
            }

            // wangqi modified 2026-04-13
            // JSON fallback: LFM2.5-VL may output JSON-format tool calls inside the standard
            // LFM2 tags, e.g. {"name":"get_date","parameters":{"offset":10},"type":"function"}.
            // Try parsing the trimmed text as JSON and extract name + arguments.
            if let toolCall = parseJSONFormat(text, tools: tools) {
                return toolCall
            }

            MLXLogCollector.shared.log("[PythonicToolCallParser] parse failed — not Pythonic or JSON. content=\(text.prefix(200))")
            return nil
        }

        let arguments = parseArguments(argsString, funcName: funcName, tools: tools)
        MLXLogCollector.shared.log("[PythonicToolCallParser] parsed Pythonic: \(funcName)(\(argsString.prefix(120)))")
        return ToolCall(function: .init(name: funcName, arguments: arguments))
    }

    // wangqi modified 2026-04-13
    /// Parse JSON-format tool call: {"name":"func","parameters":{...}} or {"name":"func","arguments":{...}}.
    /// Also handles array format: [{"name":"func","arguments":{...}}] (LFM2.5-VL output style).
    /// Used as a fallback when the Pythonic [func(arg=val)] pattern does not match.
    private func parseJSONFormat(_ text: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        guard let data = text.data(using: .utf8),
              let jsonObj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        // Support both single-object {"name":...} and array [{"name":...}] formats.
        // LFM2.5-VL outputs the array form inside <|tool_call_start|>...<|tool_call_end|>.
        let json: [String: Any]
        if let dict = jsonObj as? [String: Any] {
            json = dict
        } else if let array = jsonObj as? [[String: Any]], let first = array.first {
            json = first
        } else {
            return nil
        }

        guard let name = json["name"] as? String, !name.isEmpty else { return nil }

        // Extract argument values.
        // Prefer "parameters" when it contains actual key=value pairs (not a JSON schema).
        // A JSON schema has a top-level "properties" key with type == "object"; in that case
        // the model echoed the tool definition instead of providing values, so fall back to
        // "arguments" or an empty dict.
        let arguments: [String: any Sendable]
        let isSchema = { (d: [String: Any]) -> Bool in
            d["properties"] != nil && (d["type"] as? String) == "object"
        }
        if let params = json["parameters"] as? [String: Any], !isSchema(params) {
            arguments = convertJSONArgs(params, funcName: name, tools: tools)
            MLXLogCollector.shared.log("[PythonicToolCallParser] JSON fallback: \(name) args=\(params)")
        } else if let args = json["arguments"] as? [String: Any] {
            arguments = convertJSONArgs(args, funcName: name, tools: tools)
            MLXLogCollector.shared.log("[PythonicToolCallParser] JSON fallback (arguments key): \(name) args=\(args)")
        } else {
            arguments = [:]
            MLXLogCollector.shared.log("[PythonicToolCallParser] JSON fallback: \(name) — parameters is schema or missing, calling with empty args")
        }

        return ToolCall(function: .init(name: name, arguments: arguments))
    }

    // wangqi modified 2026-04-13
    /// Convert a raw JSON args dict (Any values) to typed [String: any Sendable] for ToolCall.
    private func convertJSONArgs(
        _ raw: [String: Any], funcName: String, tools: [[String: any Sendable]]?
    ) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in raw {
            switch value {
            case let s as String:
                result[key] = convertParameterValue(s, paramName: key, funcName: funcName, tools: tools)
            case let i as Int:    result[key] = i
            case let d as Double: result[key] = d
            case let b as Bool:   result[key] = b
            default:              result[key] = String(describing: value)
            }
        }
        return result
    }

    public func parseEOS(_ toolCallBuffer: String, tools: [[String: any Sendable]]?) -> [ToolCall] {
        if let startTag {
            return
                toolCallBuffer
                .components(separatedBy: startTag)
                .filter { !$0.isEmpty }
                .flatMap { parseMultiple(content: $0, tools: tools) }
        } else {
            return parseMultiple(content: toolCallBuffer, tools: tools)
        }
    }

    private func parseMultiple(content: String, tools: [[String: any Sendable]]?) -> [ToolCall] {
        var text = content

        if let end = endTag, let endRange = text.range(of: end) {
            text = String(text[..<endRange.lowerBound])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let regex = #/(?s)(\w+)\((.*?)\)/#
        let matches = text.matches(of: regex)

        var results: [ToolCall] = []
        for match in matches {
            let funcName = String(match.1)
            let argsString = String(match.2)
            let arguments = parseArguments(argsString, funcName: funcName, tools: tools)

            results.append(ToolCall(function: .init(name: funcName, arguments: arguments)))
        }

        return results
    }

    /// Parse Pythonic keyword arguments: arg1='value1', arg2="value2", arg3=123
    ///
    /// Values may themselves be JSON objects/arrays (e.g.
    /// `properties={"location": "Tokyo", "unit": "c"}`); splitting is bracket-,
    /// brace-, and quote-aware so commas inside a value do not truncate it.
    private func parseArguments(
        _ argsString: String,
        funcName: String,
        tools: [[String: any Sendable]]?
    ) -> [String: any Sendable] {
        var arguments: [String: any Sendable] = [:]

        for pair in splitTopLevel(argsString, separator: ",") {
            guard let eq = topLevelIndex(of: "=", in: pair) else { continue }
            let key = String(pair[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var value = String(pair[pair.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Object / array value: parse as JSON so nested commas are preserved.
            if value.hasPrefix("{") || value.hasPrefix("[") {
                if let json = tryParseJSON(value) {
                    arguments[key] = json
                    continue
                }
            }

            // Quoted string: strip surrounding quotes and unescape, then apply
            // schema-based typing (e.g. a quoted '25' for an integer parameter).
            if (value.hasPrefix("'") && value.hasSuffix("'"))
                || (value.hasPrefix("\"") && value.hasSuffix("\""))
            {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "\\'", with: "'")
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                value = value.replacingOccurrences(of: "\\\\", with: "\\")
                arguments[key] = convertParameterValue(
                    value, paramName: key, funcName: funcName, tools: tools)
                continue
            }

            // Unquoted scalar: convert based on schema type if available.
            arguments[key] = convertParameterValue(
                value, paramName: key, funcName: funcName, tools: tools)
        }

        return unwrapArgumentWrapper(arguments, funcName: funcName, tools: tools)
    }

    /// Some models wrap all arguments in a single object under a schema key —
    /// e.g. LFM2 emits `get_weather(properties={"location": "Tokyo"})`, mirroring
    /// the JSON-schema `properties` container. When the call has exactly one
    /// argument, its value is an object, and its key is a recognized wrapper name
    /// that is not itself a declared parameter, treat the inner object as the
    /// arguments. Restricted to wrapper names so a genuine object-valued argument
    /// (e.g. `configure(settings={...})`) is preserved untouched.
    private func unwrapArgumentWrapper(
        _ arguments: [String: any Sendable],
        funcName: String,
        tools: [[String: any Sendable]]?
    ) -> [String: any Sendable] {
        guard arguments.count == 1,
            let (key, value) = arguments.first,
            let object = value as? [String: any Sendable]
        else { return arguments }

        let wrapperKeys: Set<String> = ["properties", "parameters", "arguments", "args", "kwargs"]
        guard wrapperKeys.contains(key.lowercased()) else { return arguments }

        // If the wrapper name is genuinely a declared parameter, keep as-is.
        if getParameterType(funcName: funcName, paramName: key, tools: tools) != nil {
            return arguments
        }
        return object
    }

    /// Split `text` on `separator` at the top level only, ignoring separators
    /// inside quotes or `()` / `[]` / `{}` nesting.
    private func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false

        for character in text {
            if let activeQuote = quote {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                current.append(character)
            case separator where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts
    }

    /// Index of the first top-level `character` (not inside quotes or nesting).
    private func topLevelIndex(of character: Character, in text: String) -> String.Index? {
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let current = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if current == "\\" {
                    escaped = true
                } else if current == activeQuote {
                    quote = nil
                }
            } else {
                switch current {
                case "'", "\"": quote = current
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                case character where depth == 0: return index
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
