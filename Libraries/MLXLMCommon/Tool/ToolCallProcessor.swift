// Copyright © 2025 Apple Inc.

import Foundation

/// Processes generated text to detect and extract tool calls during streaming generation.
///
/// `ToolCallProcessor` handles the streaming detection of tool calls in model output,
/// buffering partial content and extracting complete tool calls when detected.
///
/// Example:
/// ```swift
/// let processor = ToolCallProcessor(format: .lfm2)
/// for chunk in generatedChunks {
///     if let text = processor.processChunk(chunk) {
///         // Regular text to display
///         print(text)
///     }
/// }
/// // After generation completes:
/// for toolCall in processor.toolCalls {
///     // Handle extracted tool calls
///     print(toolCall.function.name)
/// }
/// ```
public class ToolCallProcessor {

    // MARK: - Properties

    private let parser: any ToolCallParser
    // Bridge app-level fallback parser (ToolCallParserChain); tried after primary parse fails
    // wangqi modified 2026-03-10
    private let fallbackParser: (any ToolCallParser)?
    private let tools: [[String: any Sendable]]?
    private var state = State.normal
    private var toolCallBuffer = ""

    // wangqi modified 2026-04-13
    // Buffer for .normal-state output held back until we can confirm it is not a tool call.
    // Flushed when a newline appears (safe — tool call JSON has no bare newlines), when the
    // buffer exceeds the threshold (rules out being a short tool call), or at EOS.
    // This lets us suppress the JSON emitted by models whose <|tool_call_start|> special token
    // decodes to "" so the content arrives before <|tool_call_end|> without a visible start tag.
    private var pendingOutput: String = ""
    private let pendingOutputFlushThreshold = 512

    /// The tool calls extracted during processing.
    public var toolCalls: [ToolCall] = []

    // MARK: - State Enum

    private enum State {
        case normal
        case potentialToolCall
        case collectingToolCall
    }

    // MARK: - Initialization

    /// Initialize with a specific tool call format.
    /// - Parameters:
    ///   - format: The tool call format to use (defaults to `.json` for standard JSON format)
    ///   - tools: Optional tool schemas for type-aware parsing
    ///   - fallbackParser: Optional fallback parser tried when primary parse returns nil
    public init(format: ToolCallFormat = .json, tools: [[String: any Sendable]]? = nil,
                fallbackParser: (any ToolCallParser)? = nil) {
        self.parser = format.createParser()
        self.tools = tools
        // wangqi modified 2026-03-10
        self.fallbackParser = fallbackParser
    }

    // MARK: - Computed Properties

    /// Whether this processor uses inline format (no start tag).
    private var isInlineFormat: Bool {
        parser.startTag == nil
    }

    /// The first character of the start tag for quick detection.
    private var startTagFirstChar: Character? {
        parser.startTag?.first
    }

    // MARK: - Public Methods

    /// Process a generated text chunk and extract any tool call content.
    /// - Parameter chunk: The text chunk to process
    /// - Returns: Regular text that should be displayed (non-tool call content), or `nil` if buffering
    public func processChunk(_ chunk: String) -> String? {
        if isInlineFormat {
            return processInlineChunk(chunk)
        }
        return processTaggedChunk(chunk)
    }

    /// Process end-of-sequence, parsing any buffered content as tool call(s).
    ///
    /// Call this when generation ends (e.g., on EOS token) to handle formats
    /// whose end tag is never delivered as text (e.g., Mistral where `</s>`
    /// is intercepted at the token ID level).
    ///
    /// For formats with end tags that appear in the text stream, the buffer
    /// will already be empty at generation end, making this a no-op.
    public func processEOS() {
        guard state == .collectingToolCall || state == .potentialToolCall else { return }
        guard !toolCallBuffer.isEmpty else {
            state = .normal
            return
        }

        toolCalls.append(contentsOf: parser.parseEOS(toolCallBuffer, tools: tools))

        toolCallBuffer = ""
        state = .normal
    }

    // wangqi modified 2026-04-13
    /// Flush any text buffered in pendingOutput as regular (non-tool-call) content.
    /// Call this at EOS so buffered normal text is not silently dropped.
    public func flushPendingOutput() -> String? {
        guard !pendingOutput.isEmpty else { return nil }
        let flushed = pendingOutput
        pendingOutput = ""
        return flushed
    }

    // MARK: - Private Methods

    /// Process chunk for inline formats (no wrapper tags).
    ///
    /// Uses brace counting to detect when output looks like a JSON tool call.
    /// While braces are unbalanced the content is buffered (returns `nil`)
    /// so partial JSON is never leaked to the UI.
    private func processInlineChunk(_ chunk: String) -> String? {
        switch state {
        case .normal:
            // Check if this chunk starts what looks like a JSON tool call
            if let braceIndex = chunk.firstIndex(of: "{") {
                let leading = String(chunk[..<braceIndex])
                let jsonPart = String(chunk[braceIndex...])
                toolCallBuffer = jsonPart
                state = .collectingToolCall

                if let toolCall = parser.parse(content: toolCallBuffer, tools: tools) {
                    toolCalls.append(toolCall)
                    toolCallBuffer = ""
                    state = .normal
                    return leading.isEmpty ? nil : leading
                }

                // Still collecting — check if braces are balanced (would mean parse
                // failed on complete JSON, so it's not a tool call)
                if jsonBracesBalanced(toolCallBuffer) {
                    state = .normal
                    let buffer = toolCallBuffer
                    toolCallBuffer = ""
                    return leading + buffer
                }

                return leading.isEmpty ? nil : leading
            }

            // No brace seen — pass through as regular text
            return chunk

        case .potentialToolCall, .collectingToolCall:
            toolCallBuffer += chunk

            if let toolCall = parser.parse(content: toolCallBuffer, tools: tools) {
                toolCalls.append(toolCall)
                toolCallBuffer = ""
                state = .normal
                return nil
            }

            // If braces are balanced but parse failed, this isn't a tool call — flush
            if jsonBracesBalanced(toolCallBuffer) {
                state = .normal
                let buffer = toolCallBuffer
                toolCallBuffer = ""
                return buffer
            }

            // Still collecting
            return nil
        }
    }

    /// Check whether open/close braces are balanced in the string.
    private func jsonBracesBalanced(_ text: String) -> Bool {
        var depth = 0
        for ch in text {
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
        }
        return depth == 0
    }

    /// Process chunk for tagged formats.
    private func processTaggedChunk(_ chunk: String) -> String? {
        guard let startTag = parser.startTag,
            let startChar = startTagFirstChar
        else {
            return chunk
        }

        // wangqi modified 2026-04-13
        // In .normal state with no start character: buffer instead of emitting immediately.
        // This allows us to detect the invisible-start-tag pattern used by LFM2.5-VL, where
        // <|tool_call_start|> decodes to "" and the JSON body arrives before <|tool_call_end|>.
        // We flush on newline (safe — tool call JSON has no bare newlines) or when the buffer
        // grows large enough to rule out being a short tool call prefix.
        if state == .normal && !chunk.contains(startChar) {
            pendingOutput += chunk
            // Don't flush JSON-starting buffers on newline: models like Ternary-Bonsai emit
            // JSON\n</tool_call> where the \n separates the JSON from the end tag, not a sign
            // that the buffer isn't a tool call.
            // wangqi modified 2026-04-19
            let mightBeToolCall = pendingOutput.hasPrefix("{")
            if (!mightBeToolCall && pendingOutput.contains("\n")) || pendingOutput.count >= pendingOutputFlushThreshold {
                let flushed = pendingOutput
                pendingOutput = ""
                return flushed
            }
            return nil
        }

        toolCallBuffer += chunk
        var leadingToken: String?

        switch state {
        case .normal:
            // Change state to potential tool call
            state = .potentialToolCall

            leadingToken = separateToken(
                from: &toolCallBuffer, separator: String(startChar), returnLeading: true)

            fallthrough
        case .potentialToolCall:
            if partialMatch(buffer: toolCallBuffer, tag: startTag) {
                if toolCallBuffer.starts(with: startTag) {
                    state = .collectingToolCall
                    fallthrough
                } else {
                    return nil
                }
            } else {
                state = .normal
                let buffer = toolCallBuffer
                toolCallBuffer = ""

                // wangqi modified 2026-04-13
                // If the failed buffer starts with the end tag, the model used an invisible start
                // tag (e.g. <|tool_call_start|> decoded to ""). The JSON content accumulated in
                // pendingOutput; try parsing it as a tool call and suppress output if it succeeds.
                if let endTag = parser.endTag, buffer.hasPrefix(endTag), !pendingOutput.isEmpty {
                    let content = pendingOutput
                    pendingOutput = ""
                    let trailing = String(buffer.dropFirst(endTag.count))
                    if let toolCall = parser.parse(content: content, tools: tools)
                        ?? fallbackParser?.parse(content: content, tools: tools) {
                        toolCalls.append(toolCall)
                        let result = (leadingToken ?? "") + trailing
                        return result.isEmpty ? nil : result
                    }
                    // Parse failed — flush everything as plain text
                    return (leadingToken ?? "") + content + buffer
                }

                // Normal match failure — flush any remaining pending output along with leading+buffer
                let pending = pendingOutput
                pendingOutput = ""
                let result = (leadingToken ?? "") + pending + buffer
                return result.isEmpty ? nil : result
            }
        case .collectingToolCall:
            guard let endTag = parser.endTag else {
                return nil
            }

            if toolCallBuffer.contains(endTag) {
                // Separate the trailing token
                let trailingToken = separateToken(
                    from: &toolCallBuffer, separator: endTag, returnLeading: false)

                // wangqi modified 2026-03-10: try fallbackParser when primary parse returns nil
                if let toolCall = parser.parse(content: toolCallBuffer, tools: tools)
                    ?? fallbackParser?.parse(content: toolCallBuffer, tools: tools) {
                    toolCalls.append(toolCall)
                }

                state = .normal
                toolCallBuffer = ""

                // If the token contains the start character, there may be more tool calls to come
                if let trailingToken, let startChar = startTagFirstChar,
                    trailingToken.contains(startChar)
                {
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
}
