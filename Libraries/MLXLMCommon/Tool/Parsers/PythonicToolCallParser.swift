// Copyright © 2025 Apple Inc.

import Foundation

/// Parser for Pythonic tool call format: [function_name(arg1='value1', arg2='value2')]
/// Used by LFM2.5 and similar models that output tool calls in Python function call syntax.
/// Reference: LiquidAI LFM2.5 chat template format
public struct PythonicToolCallParser: ToolCallParser, Sendable {
    public let startTag: String?
    public let endTag: String?

    /// Python string literals use either quote character, and values may nest
    /// any bracket kind, so every scan of this dialect shares one configuration.
    private static let scanner = StructuredTextScanner(quotes: ["'", "\""])

    public init(startTag: String? = nil, endTag: String? = nil) {
        self.startTag = startTag
        self.endTag = endTag
    }

    public func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall? {
        parseMultiple(content: content, tools: tools).first
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
        let text = unwrapped(content)
        let calls = callBodies(in: text).compactMap { parseCall($0, tools: tools) }
        if !calls.isEmpty {
            MLXLogCollector.shared.log(
                "[PythonicToolCallParser] parsed Pythonic: "
                    + calls.map(\.function.name).joined(separator: ","))
            return calls
        }

        // wangqi modified 2026-04-13 / re-merged onto upstream's scanner-based parser 2026-08-31.
        // JSON fallback: LFM2.5-VL emits JSON-format tool calls inside the standard LFM2 tags,
        // e.g. {"name":"get_date","parameters":{"offset":10},"type":"function"} (and the array
        // form of the same). Upstream's Pythonic scanner cannot reach that shape at all — it
        // requires a top-level `(` — so the two paths are disjoint, and this now covers parseEOS
        // as well as parse.
        if let toolCall = parseJSONFormat(String(text), tools: tools) {
            return [toolCall]
        }

        MLXLogCollector.shared.log(
            "[PythonicToolCallParser] parse failed - not Pythonic or JSON. content=\(text.prefix(200))")
        return []
    }

    /// Strips the protocol tags and surrounding whitespace, leaving the call list.
    private func unwrapped(_ content: String) -> Substring {
        var text = content[...]

        if let startTag, let startRange = text.range(of: startTag) {
            text = text[startRange.upperBound...]
        }
        if let endTag, let endRange = text.range(of: endTag) {
            text = text[..<endRange.lowerBound]
        }

        return text.trimmingWhitespace()
    }

    /// Splits a call list into one body per call.
    ///
    /// The list may be wrapped in `[...]`, which has to balance: a bracket left
    /// open means the payload is truncated, not that the calls inside it are
    /// ready to execute. Bodies are separated by top-level commas, so a comma
    /// inside an argument value never splits one call into two.
    private func callBodies(in text: Substring) -> [Substring] {
        var list = text

        if list.first == "[" {
            guard let end = Self.scanner.endOfGroup(in: list, openedAt: list.startIndex)
            else { return [] }
            list = list[list.index(after: list.startIndex) ..< end]
        }

        return Self.scanner.splitTopLevel(list, separator: ",")
    }

    /// Parses one `name(arguments)` body.
    ///
    /// The argument list ends at the parenthesis balancing the one that opened
    /// it, so a value containing `)`, `]`, or `)]` survives intact.
    private func parseCall(_ body: Substring, tools: [[String: any Sendable]]?) -> ToolCall? {
        let body = body.trimmingWhitespace()
        guard let open = Self.scanner.firstTopLevelIndex(of: "(", in: body),
            let close = Self.scanner.endOfGroup(in: body, openedAt: open)
        else { return nil }

        let name = identifierEnding(at: open, in: body)
        guard !name.isEmpty else { return nil }

        let funcName = String(name)
        let arguments = parseArguments(
            String(body[body.index(after: open) ..< close]), funcName: funcName, tools: tools)
        return ToolCall(function: .init(name: funcName, arguments: arguments))
    }

    /// The identifier run ending just before `index`, which skips whatever list
    /// punctuation or qualifier the model emitted ahead of the call.
    private func identifierEnding(at index: String.Index, in body: Substring) -> Substring {
        let prefix = body[..<index]
        let isIdentifier: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        guard let boundary = prefix.lastIndex(where: { !isIdentifier($0) }) else { return prefix }
        return prefix[prefix.index(after: boundary)...]
    }

    /// Parse Pythonic keyword arguments: arg1='value1', arg2="value2", arg3=123
    ///
    /// Values may be JSON or Python literals, including single-quoted collections
    /// and the `True`, `False`, and `None` spellings. Splitting is bracket-, brace-,
    /// and quote-aware so commas inside a value do not truncate it.
    private func parseArguments(
        _ argsString: String,
        funcName: String,
        tools: [[String: any Sendable]]?
    ) -> [String: any Sendable] {
        var arguments: [String: any Sendable] = [:]

        for pair in Self.scanner.splitTopLevel(argsString[...], separator: ",") {
            guard let eq = Self.scanner.firstTopLevelIndex(of: "=", in: pair) else { continue }
            let key = String(pair[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = pair[pair.index(after: eq)...].trimmingWhitespace()
            arguments[key] = parseArgumentValue(
                value, key: key, funcName: funcName, tools: tools)
        }

        return unwrapArgumentWrapper(arguments, funcName: funcName, tools: tools)
    }

    /// Converts one argument without letting inferred scalar types override a
    /// declared schema. Collections retain the parser's historical eager
    /// decoding behavior, now with Python-literal syntax as a fallback.
    private func parseArgumentValue(
        _ value: Substring,
        key: String,
        funcName: String,
        tools: [[String: any Sendable]]?
    ) -> any Sendable {
        let literal = String(value)

        if value.first == "{" || value.first == "[" {
            return tryParseJSON(literal) ?? tryParsePythonLiteral(literal) ?? literal
        }

        if value.first == "'" || value.first == "\"" {
            let string = (tryParsePythonLiteral(literal) as? String) ?? literal
            return convertParameterValue(
                string, paramName: key, funcName: funcName, tools: tools)
        }

        if getParameterType(funcName: funcName, paramName: key, tools: tools) != nil {
            return convertParameterValue(
                literal, paramName: key, funcName: funcName, tools: tools)
        }

        return tryParsePythonLiteral(literal) ?? literal
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
}
