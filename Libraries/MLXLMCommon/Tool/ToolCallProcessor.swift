// Copyright © 2025 Apple Inc.

import Foundation

/// Used to process generated text to detect tool calls and manage the generation flow
public class ToolCallProcessor {

    // wangqi [2026-01-07] - Changed from static to instance for configurability
    private let toolUseStartTag: String
    private let toolUseEndTag: String
    private let startTagFirstChar: Character
    private let toolCallRegex: Regex<AnyRegexOutput>

    // wangqi [2026-01-07] - Added configurable initializer
    public init(startTag: String = "<tool_call>", endTag: String = "</tool_call>") {
        self.toolUseStartTag = startTag
        self.toolUseEndTag = endTag
        self.startTagFirstChar = startTag.first ?? "<"

        // Build regex dynamically - escape special chars
        let escapedStart = NSRegularExpression.escapedPattern(for: startTag)
        let escapedEnd = NSRegularExpression.escapedPattern(for: endTag)
        let pattern = "\(escapedStart)\\s*(\\{.*?\\})\\s*\(escapedEnd)"
        self.toolCallRegex = try! Regex(pattern)

        // wangqi [2026-01-07] - Debug log for initialization
        print("[ToolCallProcessor] Initialized with startTag: '\(startTag)', endTag: '\(endTag)', pattern: '\(pattern)'")
    }

    // Track the current state of processing
    private enum State {
        case normal
        case potentialToolCall
        case collectingToolCall
    }

    private var state = State.normal
    private var toolCallBuffer = ""

    /// The current parsed tool call, if any
    public var toolCalls: [ToolCall] = []

    // wangqi [2026-01-07] - Track accumulated text for debugging
    private var accumulatedText = ""

    /// Append a generated text chunk and process for tool call tags
    /// - Parameter chunk: The text chunk to process
    /// - Returns: Any regular text that should be yielded (non-tool call content)
    public func processChunk(_ chunk: String) -> String? {
        // wangqi [2026-01-07] - Debug: track accumulated text
        accumulatedText += chunk

        // wangqi [2026-01-07] - Use instance startTagFirstChar instead of hardcoded "<"
        guard (state == .normal && chunk.contains(String(startTagFirstChar))) || state != .normal else {
            return chunk
        }

        // wangqi [2026-01-07] - Debug log when potential tool call detected
        print("[ToolCallProcessor] Potential tool call detected. Chunk: '\(chunk)', State: \(state), Buffer: '\(toolCallBuffer)')")

        toolCallBuffer += chunk
        var leadingToken: String?

        switch state {
        case .normal:
            // Change state to potential tool call
            state = .potentialToolCall

            // wangqi [2026-01-07] - Use instance startTagFirstChar
            leadingToken = separateToken(from: &toolCallBuffer, separator: String(startTagFirstChar), returnLeading: true)

            fallthrough
        case .potentialToolCall:
            // wangqi [2026-01-07] - Use instance toolUseStartTag
            if partialMatch(buffer: toolCallBuffer, tag: toolUseStartTag) {
                if toolCallBuffer.starts(with: toolUseStartTag) {
                    state = .collectingToolCall
                    fallthrough
                } else {
                    return nil
                }
            } else {
                // Otherwise, return the collected text and reset the state
                state = .normal
                let buffer = toolCallBuffer
                toolCallBuffer = ""
                return (leadingToken ?? "") + buffer
            }
        case .collectingToolCall:
            // wangqi [2026-01-07] - Use instance toolUseEndTag
            if toolCallBuffer.contains(toolUseEndTag) {
                // Separate the trailing token
                let trailingToken = separateToken(
                    from: &toolCallBuffer, separator: toolUseEndTag, returnLeading: false)

                // Parse the tool call
                // wangqi [2026-01-07] - Debug log before parsing
                print("[ToolCallProcessor] Attempting to parse tool call from buffer: '\(toolCallBuffer)'")
                if let toolCall = parseToolCall(toolCallBuffer) {
                    toolCalls.append(toolCall)
                    print("[ToolCallProcessor] Successfully parsed tool call: \(toolCall.function.name)")
                } else {
                    print("[ToolCallProcessor] Failed to parse tool call from buffer")
                }

                state = .normal
                toolCallBuffer = ""

                // wangqi [2026-01-07] - Use instance startTagFirstChar
                if let trailingToken, trailingToken.contains(String(startTagFirstChar)) {
                    return processChunk(trailingToken)
                } else {
                    // Otherwise, return the collected token, or nil if it's empty
                    return trailingToken?.isEmpty ?? true ? nil : trailingToken
                }
            } else {
                return nil
            }
        }
    }

    /// Separates a token from a string buffer based on a separator
    /// - Parameters:
    ///   - buffer: The string buffer to modify
    ///   - separator: The separator string to search for
    ///   - returnLeading: If true, returns text before separator; if false, returns text after
    /// - Returns: The separated token, or nil if separator not found
    private func separateToken(from buffer: inout String, separator: String, returnLeading: Bool)
        -> String?
    {
        guard let range = buffer.range(of: separator) else { return nil }

        let token: String
        if returnLeading {
            token = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.lowerBound...])
        } else {
            token = String(buffer[range.upperBound...])
            buffer = String(buffer[..<range.upperBound])
        }

        return token
    }

    private func partialMatch(buffer: String, tag: String) -> Bool {
        for (tagIndex, bufferIndex) in zip(tag.indices, buffer.indices) {
            if buffer[bufferIndex] != tag[tagIndex] {
                return false
            }
        }

        return true
    }

    /// Parse a tool call from the content inside <tool_use> tags
    private func parseToolCall(_ content: String) -> ToolCall? {
        guard let match = content.firstMatch(of: toolCallRegex) else { return nil }

        // wangqi [2026-01-07] - For Regex<AnyRegexOutput>, use subscript access
        guard match.output.count > 1,
              let captured = match.output[1].substring else { return nil }
        let jsonData = String(captured).data(using: .utf8)!

        if let json = try? JSONDecoder().decode(ToolCall.Function.self, from: jsonData) {
            return ToolCall(function: json)
        } else {
            return nil
        }
    }
}
