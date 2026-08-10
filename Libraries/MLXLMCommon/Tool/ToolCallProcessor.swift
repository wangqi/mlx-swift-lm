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

    /// An ordered item emitted while processing generated output.
    public enum Output: Sendable, Equatable {
        case response(String)
        case toolCall(ToolCall)
    }

    // MARK: - Properties

    private let format: ToolCallFormat
    private let parser: any ToolCallParser
    // Bridge app-level fallback parser (ToolCallParserChain); tried after primary parse fails
    // wangqi modified 2026-03-10
    private let fallbackParser: (any ToolCallParser)?
    private let tools: [[String: any Sendable]]?
    private let supportsBareJSONFallback: Bool
    private let maxJSONFallbackBufferLength = 32_768
    private let jsonObjectScanner = JSONLeadingObjectScanner(startCharacter: "{")
    private var state = State.normal
    private var toolCallBuffer = ""
    private var emittedToolCallIDs: Set<String> = []
    private var orderedOutputQueue: [Output] = []
    private var orderedOutputEnabled = false

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
        case collectingJSONToolCall
    }

    private enum TaggedStartMode {
        case none
        case tagged
        case bareJSON
    }

    // MARK: - Initialization

    /// Initialize with a specific tool call format.
    /// - Parameters:
    ///   - format: The tool call format to use (defaults to `.json` for standard JSON format)
    ///   - tools: Optional tool schemas for type-aware parsing
    ///   - fallbackParser: Optional fallback parser tried when primary parse returns nil
    public init(format: ToolCallFormat = .json, tools: [[String: any Sendable]]? = nil,
                fallbackParser: (any ToolCallParser)? = nil) {
        self.format = format
        self.parser = format.createParser()
        self.tools = tools
        // wangqi modified 2026-03-10
        self.fallbackParser = fallbackParser
        self.supportsBareJSONFallback = format == .json
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

    /// Processes a generated chunk and removes its output in source order.
    ///
    /// Tool protocol syntax that does not parse as a call is not emitted as a
    /// response. Use this streaming operation when tool calls and response text
    /// must retain their relative order. Do not mix this API with `processChunk`,
    /// `processEOS`, or `drainToolCalls()` on the same processor instance.
    public func processChunkOutputs(_ chunk: String) -> [Output] {
        orderedOutputEnabled = true
        let outputCount = orderedOutputQueue.count
        let visible = processChunk(chunk)
        if orderedOutputQueue.count == outputCount, let visible {
            recordResponse(sanitizingProtocol: visible)
        }
        _ = drainToolCalls()
        return drainOrderedOutputs()
    }

    /// Removes and returns every parsed call in parse order.
    /// A second call returns an empty array until more chunks are processed.
    public func drainToolCalls() -> [ToolCall] {
        guard !toolCalls.isEmpty else { return [] }
        let drained = toolCalls
        toolCalls.removeAll(keepingCapacity: true)
        return drained
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
        _ = processEOS(returnBufferedText: false)
    }

    /// Process end-of-sequence and optionally return residual buffered text.
    ///
    /// Use this overload when callers need to preserve non-tool trailing content
    /// that remained buffered until generation end.
    ///
    /// - Parameter returnBufferedText: When `true`, returns residual text if no
    ///   tool call was parsed from the buffered content.
    /// - Returns: Residual buffered text that should be emitted as regular output,
    ///   or `nil` when the buffer was fully parsed as tool call content (or when
    ///   `returnBufferedText` is `false`).
    @discardableResult
    public func processEOS(returnBufferedText: Bool = true) -> String? {
        guard
            state == .collectingToolCall || state == .potentialToolCall
                || state == .collectingJSONToolCall
        else { return nil }
        guard !toolCallBuffer.isEmpty else {
            state = .normal
            return nil
        }

        let buffered = toolCallBuffer
        let parsedCalls = parser.parseEOS(buffered, tools: tools)
        appendToolCalls(parsedCalls)

        toolCallBuffer = ""
        state = .normal

        return returnBufferedText && parsedCalls.isEmpty ? buffered : nil
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

    /// Finishes processing and removes residual output in source order.
    ///
    /// This preserves non-tool text following EOS-delimited calls. Do not mix
    /// this API with the legacy processing and draining APIs.
    public func processEOSOutputs() -> [Output] {
        orderedOutputEnabled = true
        if format == .mistral, let outputs = processMistralEOSOutputs() {
            orderedOutputQueue.removeAll(keepingCapacity: true)
            return outputs
        }
        if format == .lfm2, let outputs = processLFM2EOSOutputs() {
            orderedOutputQueue.removeAll(keepingCapacity: true)
            return outputs
        }

        let outputCount = orderedOutputQueue.count
        let visible = processEOS(returnBufferedText: true)
        if orderedOutputQueue.count == outputCount, let visible {
            recordEOSResidual(visible)
        }
        _ = drainToolCalls()
        return drainOrderedOutputs()
    }

    // MARK: - Private Methods

    /// Process chunk for inline formats (no wrapper tags).
    ///
    /// Uses quote-aware JSON object scanning to detect when output looks like a JSON tool call.
    /// While the object is incomplete the content is buffered (returns `nil`)
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
                    recordResponse(leading.replacingOccurrences(of: "<|python_tag|>", with: ""))
                    appendToolCall(toolCall)
                    toolCallBuffer = ""
                    state = .normal
                    return leading.isEmpty ? nil : leading
                }

                // Still collecting — check if the first JSON object is complete (would mean parse
                // failed on complete JSON, so it's not a tool call)
                if jsonObjectScanner.splitLeadingObject(from: toolCallBuffer) != nil {
                    state = .normal
                    let buffer = toolCallBuffer
                    toolCallBuffer = ""
                    let response = leading + buffer
                    recordResponse(sanitizingProtocol: response)
                    return response
                }

                recordResponse(sanitizingProtocol: leading)
                return leading.isEmpty ? nil : leading
            }

            // No brace seen — pass through as regular text
            recordResponse(sanitizingProtocol: chunk)
            return chunk

        case .potentialToolCall, .collectingToolCall, .collectingJSONToolCall:
            toolCallBuffer += chunk

            if let toolCall = parser.parse(content: toolCallBuffer, tools: tools) {
                appendToolCall(toolCall)
                toolCallBuffer = ""
                state = .normal
                return nil
            }

            // If the object is complete but parse failed, this isn't a tool call — flush
            if jsonObjectScanner.splitLeadingObject(from: toolCallBuffer) != nil {
                state = .normal
                let buffer = toolCallBuffer
                toolCallBuffer = ""
                recordResponse(sanitizingProtocol: buffer)
                return buffer
            }

            // Still collecting
            return nil
        }
    }

    private func appendResponse(_ text: String, to outputs: inout [Output]) {
        guard !text.isEmpty else { return }
        outputs.append(.response(text))
    }

    private func recordResponse(_ text: String) {
        guard orderedOutputEnabled, !text.isEmpty else { return }
        orderedOutputQueue.append(.response(text))
    }

    private func recordResponse(sanitizingProtocol text: String) {
        recordResponse(stripProtocolSpans(from: text))
    }

    private func recordEOSResidual(_ text: String) {
        recordResponse(sanitizeEOSResidual(text))
    }

    private func drainOrderedOutputs() -> [Output] {
        let outputs = orderedOutputQueue
        orderedOutputQueue.removeAll(keepingCapacity: true)
        return outputs
    }

    private func stripProtocolSpans(from text: String) -> String {
        var result = text
        let tags =
            [parser.startTag, parser.endTag].compactMap { $0 }
            + (format == .llama3 ? ["<|python_tag|>"] : [])

        for tag in tags {
            while let range = result.range(of: tag) {
                if tag == parser.startTag,
                    let endTag = parser.endTag,
                    let end = result.range(of: endTag, range: range.upperBound ..< result.endIndex)
                {
                    result.removeSubrange(range.lowerBound ..< end.upperBound)
                } else {
                    result.removeSubrange(range)
                }
            }

            guard let first = tag.first else { continue }
            var index = result.startIndex
            while index < result.endIndex {
                guard result[index] == first else {
                    index = result.index(after: index)
                    continue
                }
                let suffix = result[index...]
                let matchCount = zip(suffix, tag).prefix { $0 == $1 }.count
                guard matchCount >= nearCompleteMatchLength(for: tag) else {
                    index = result.index(after: index)
                    continue
                }
                let markerEnd =
                    suffix.firstIndex(of: ">")
                    ?? suffix.firstIndex(of: "]")
                let removalEnd = markerEnd.map { result.index(after: $0) } ?? result.endIndex
                result.removeSubrange(index ..< removalEnd)
            }
        }
        return result
    }

    private func sanitizeEOSResidual(_ text: String) -> String {
        guard let startTag = parser.startTag else {
            return stripProtocolSpans(from: text)
        }

        var searchStart = text.startIndex
        while let startRange = text.range(of: startTag, range: searchStart ..< text.endIndex) {
            guard
                let endTag = parser.endTag,
                let endRange = text.range(
                    of: endTag, range: startRange.upperBound ..< text.endIndex)
            else {
                return stripProtocolSpans(from: String(text[..<startRange.lowerBound]))
            }
            searchStart = endRange.upperBound
        }
        return stripProtocolSpans(from: text)
    }

    private func nearCompleteMatchLength(for tag: String) -> Int {
        max(tag.count - 2, 1)
    }

    private func processMistralEOSOutputs() -> [Output]? {
        guard
            state == .collectingToolCall || state == .potentialToolCall
                || state == .collectingJSONToolCall,
            !toolCallBuffer.isEmpty
        else { return nil }

        let startTag = "[TOOL_CALLS]"
        let argsTag = "[ARGS]"
        var remaining = toolCallBuffer
        var outputs: [Output] = []

        while remaining.hasPrefix(startTag) {
            guard let argsRange = remaining.range(of: argsTag) else { break }
            let arguments = String(remaining[argsRange.upperBound...])
            guard let split = jsonObjectScanner.splitLeadingObject(from: arguments) else { break }

            let callText = String(remaining[..<argsRange.upperBound]) + split.object
            guard let call = parser.parse(content: callText, tools: tools) else { break }
            appendToolCall(call)
            outputs.append(.toolCall(toolCalls.removeLast()))
            remaining = split.trailing
        }

        toolCallBuffer = ""
        state = .normal

        if !remaining.isEmpty {
            appendResponse(sanitizeEOSResidual(remaining), to: &outputs)
        }
        return outputs
    }

    private func processLFM2EOSOutputs() -> [Output]? {
        guard
            state == .collectingToolCall || state == .potentialToolCall
                || state == .collectingJSONToolCall,
            !toolCallBuffer.isEmpty,
            let startTag = parser.startTag
        else { return nil }

        var remaining = toolCallBuffer
        var outputs: [Output] = []

        while let startRange = remaining.range(of: startTag) {
            let responsePrefix = String(remaining[..<startRange.lowerBound])
            let callStart = startRange.upperBound
            guard let callEnd = balancedBracketEnd(in: remaining, from: callStart) else { break }

            let callText = String(remaining[startRange.lowerBound ... callEnd])
            guard let call = parser.parse(content: callText, tools: tools) else { break }
            appendResponse(stripProtocolSpans(from: responsePrefix), to: &outputs)
            appendToolCall(call)
            outputs.append(.toolCall(toolCalls.removeLast()))
            remaining = String(remaining[remaining.index(after: callEnd)...])
        }

        toolCallBuffer = ""
        state = .normal

        if !remaining.isEmpty {
            appendResponse(sanitizeEOSResidual(remaining), to: &outputs)
        }
        return outputs
    }

    private func balancedBracketEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var stringQuote: Character?
        var escaped = false

        for index in text.indices[start...] {
            let character = text[index]
            if let quote = stringQuote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    stringQuote = nil
                }
                continue
            }
            switch character {
            case "\"", "'": stringQuote = character
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// Process chunk for tagged formats.
    private func processTaggedChunk(_ chunk: String) -> String? {
        guard let startTag = parser.startTag,
            let startChar = startTagFirstChar
        else {
            return chunk
        }

        let startMode =
            state == .normal
            ? taggedStartMode(in: chunk, startChar: startChar)
            : .none

        // wangqi modified 2026-04-13 (merged with upstream's ordered-output recording 2026-08-10)
        // In .normal state with no start indicator: for tagged-only formats, buffer instead of
        // emitting immediately. This detects the invisible-start-tag pattern used by LFM2.5-VL,
        // where <|tool_call_start|> decodes to "" and the JSON body arrives before
        // <|tool_call_end|>. We flush on newline (safe — tool call JSON has no bare newlines) or
        // when the buffer grows large enough to rule out being a short tool call prefix.
        // Bare-JSON-capable formats keep upstream's immediate emission (and bareJSON detection),
        // so the two features never interact.
        // Every emitting path calls recordResponse so callers on upstream's ordered-output API
        // see the same text, in source order, that the legacy return value carries.
        if state == .normal && startMode == .none {
            if supportsBareJSONFallback {
                recordResponse(chunk)
                return chunk
            }
            pendingOutput += chunk
            // Don't flush JSON-starting buffers on newline: models like Ternary-Bonsai emit
            // JSON\n</tool_call> where the \n separates the JSON from the end tag, not a sign
            // that the buffer isn't a tool call.
            // wangqi modified 2026-04-19
            let mightBeToolCall = pendingOutput.hasPrefix("{")
            if (!mightBeToolCall && pendingOutput.contains("\n")) || pendingOutput.count >= pendingOutputFlushThreshold {
                let flushed = pendingOutput
                pendingOutput = ""
                recordResponse(flushed)
                return flushed
            }
            return nil
        }

        toolCallBuffer += chunk
        var leadingToken: String?
        var leadingTokenWasRecorded = false

        switch state {
        case .normal:
            if startMode == .bareJSON {
                // Fallback for models that sporadically emit bare JSON tool calls.
                state = .collectingJSONToolCall

                leadingToken = separateToken(
                    from: &toolCallBuffer,
                    separator: String(jsonObjectScanner.startCharacter),
                    returnLeading: true
                )

                return processCollectingJSONToolCall(
                    startTag: startTag,
                    startChar: startChar,
                    leadingToken: leadingToken
                )
            }

            guard startMode == .tagged else {
                return chunk
            }

            // Change state to potential tagged tool call.
            state = .potentialToolCall

            leadingToken = separateToken(
                from: &toolCallBuffer, separator: String(startChar), returnLeading: true)

            fallthrough

        case .potentialToolCall:
            if partialMatch(buffer: toolCallBuffer, tag: startTag) {
                if toolCallBuffer.starts(with: startTag) {
                    state = .collectingToolCall
                    recordResponse(leadingToken ?? "")
                    leadingTokenWasRecorded = true
                    fallthrough
                } else {
                    recordResponse(leadingToken ?? "")
                    leadingTokenWasRecorded = true
                    return nil
                }
            } else {
                // Otherwise, return the collected text and reset the state.
                state = .normal
                let buffer = toolCallBuffer
                toolCallBuffer = ""

                // wangqi modified 2026-04-13 (merged with upstream's ordered-output recording
                // 2026-08-10). If the failed buffer starts with the end tag, the model used an
                // invisible start tag (e.g. <|tool_call_start|> decoded to ""). The JSON content
                // accumulated in pendingOutput; try parsing it as a tool call and suppress the
                // output if it succeeds.
                if let endTag = parser.endTag, buffer.hasPrefix(endTag), !pendingOutput.isEmpty {
                    let content = pendingOutput
                    pendingOutput = ""
                    let trailing = String(buffer.dropFirst(endTag.count))
                    if let toolCall = parser.parse(content: content, tools: tools)
                        ?? fallbackParser?.parse(content: content, tools: tools) {
                        // Record in source order: leading text, then the call, then the trailing
                        // text. appendToolCall (not toolCalls.append) so the call also reaches the
                        // ordered-output queue and gets its id normalized.
                        if !leadingTokenWasRecorded {
                            recordResponse(leadingToken ?? "")
                        }
                        appendToolCall(toolCall)
                        recordResponse(trailing)
                        let result = (leadingToken ?? "") + trailing
                        return result.isEmpty ? nil : result
                    }
                    // Parse failed — flush everything as plain text
                    let response = (leadingToken ?? "") + content + buffer
                    recordResponse(sanitizingProtocol: response)
                    return response
                }

                // Normal match failure — flush any remaining pending output along with leading+buffer
                let pending = pendingOutput
                pendingOutput = ""
                let response = (leadingToken ?? "") + pending + buffer
                recordResponse(sanitizingProtocol: response)
                return response.isEmpty ? nil : response
            }

        case .collectingToolCall:
            guard let endTag = parser.endTag else {
                return nil
            }

            if toolCallBuffer.contains(endTag) {
                // Separate the trailing token.
                let trailingToken = separateToken(
                    from: &toolCallBuffer, separator: endTag, returnLeading: false)

                let bufferedToolCall = toolCallBuffer

                // Parse the tool call using the parser, then the fork's fallbackParser when the
                // primary parse returns nil — wangqi modified 2026-03-10 (merged 2026-07-03,
                // re-merged onto upstream's ordered-output recording 2026-08-10). Matches the
                // sibling inline-parse site above at collectingText.
                if let toolCall = parser.parse(content: bufferedToolCall, tools: tools)
                    ?? fallbackParser?.parse(content: bufferedToolCall, tools: tools) {
                    if !leadingTokenWasRecorded {
                        recordResponse(leadingToken ?? "")
                    }
                    appendToolCall(toolCall)
                    state = .normal
                    toolCallBuffer = ""

                    // If trailing content may contain another tool call, recurse.
                    if let trailingToken,
                        tokenCouldContainToolStart(trailingToken, startChar: startChar)
                    {
                        return combine(leadingToken, processChunk(trailingToken))
                    }

                    // Otherwise, return trailing text if non-empty.
                    let trailingText = trailingToken?.isEmpty ?? true ? nil : trailingToken
                    if let trailingText { recordResponse(trailingText) }
                    return combine(leadingToken, trailingText)
                }

                // Preserve unparsed tagged payload as plain text, then continue scanning.
                state = .normal
                toolCallBuffer = ""
                if !leadingTokenWasRecorded {
                    recordResponse(leadingToken ?? "")
                }
                if let trailingToken,
                    tokenCouldContainToolStart(trailingToken, startChar: startChar)
                {
                    return combine(
                        leadingToken,
                        combine(bufferedToolCall, processChunk(trailingToken))
                    )
                }
                if let trailingToken { recordResponse(trailingToken) }
                return combine(leadingToken, combine(bufferedToolCall, trailingToken))
            }

            return nil

        case .collectingJSONToolCall:
            return processCollectingJSONToolCall(
                startTag: startTag,
                startChar: startChar,
                leadingToken: leadingToken
            )
        }
    }

    private func processCollectingJSONToolCall(
        startTag: String,
        startChar: Character,
        leadingToken: String?
    ) -> String? {
        if toolCallBuffer.count > maxJSONFallbackBufferLength {
            // Safety valve: flush pathological unmatched JSON-like buffers as text.
            state = .normal
            let buffered = toolCallBuffer
            toolCallBuffer = ""
            let response = (leadingToken ?? "") + buffered
            recordResponse(sanitizingProtocol: response)
            return response
        }

        switch jsonObjectScanner.evaluatePrefix(in: toolCallBuffer) {
        case .invalidObject:
            state = .normal
            let buffered = toolCallBuffer
            toolCallBuffer = ""
            // vLLM-style recovery: if a tagged tool call exists later, retry tagged parsing.
            if buffered.contains(startTag) {
                recordResponse(leadingToken ?? "")
                return combine(leadingToken, processChunk(buffered))
            }
            let response = (leadingToken ?? "") + buffered
            recordResponse(sanitizingProtocol: response)
            return response
        case .needsMore, .validObject:
            break
        }

        guard let split = jsonObjectScanner.splitLeadingObject(from: toolCallBuffer) else {
            // Continue buffering until a complete top-level JSON object is available.
            recordResponse(leadingToken ?? "")
            return leadingToken?.isEmpty ?? true ? nil : leadingToken
        }

        let jsonCandidate = split.object
        let trailingToken = split.trailing

        if let toolCall = parser.parse(content: jsonCandidate, tools: tools) {
            recordResponse(leadingToken ?? "")
            appendToolCall(toolCall)

            state = .normal
            toolCallBuffer = ""

            if trailingToken.isEmpty {
                return leadingToken?.isEmpty ?? true ? nil : leadingToken
            }

            if tokenCouldContainToolStart(trailingToken, startChar: startChar) {
                return combine(leadingToken, processChunk(trailingToken))
            }

            recordResponse(trailingToken)
            return combine(leadingToken, trailingToken)
        }

        // If it looked like JSON but is not a valid tool call payload,
        // flush it back as normal text while still scanning trailing content.
        state = .normal
        toolCallBuffer = ""
        if tokenCouldContainToolStart(trailingToken, startChar: startChar) {
            recordResponse((leadingToken ?? "") + jsonCandidate)
            return combine(leadingToken, combine(jsonCandidate, processChunk(trailingToken)))
        }
        let response = (leadingToken ?? "") + jsonCandidate + trailingToken
        recordResponse(sanitizingProtocol: response)
        return response
    }

    private func taggedStartMode(
        in chunk: String,
        startChar: Character
    ) -> TaggedStartMode {
        let taggedStartIndex = chunk.firstIndex(of: startChar)
        let jsonStartIndex =
            supportsBareJSONFallback
            ? chunk.firstIndex(of: jsonObjectScanner.startCharacter)
            : nil

        switch (taggedStartIndex, jsonStartIndex) {
        case (nil, nil):
            return .none
        case (.some, nil):
            return .tagged
        case (nil, .some):
            return .bareJSON
        case (.some(let tagged), .some(let json)):
            if json >= tagged {
                return .tagged
            }

            // If the earlier `{` cannot begin a JSON object, prefer tagged parsing.
            if case .invalidObject = jsonObjectScanner.evaluatePrefix(in: chunk, from: json) {
                return .tagged
            }

            return .bareJSON
        }
    }

    private func tokenCouldContainToolStart(_ token: String, startChar: Character) -> Bool {
        token.contains(startChar)
            || (supportsBareJSONFallback && token.contains(jsonObjectScanner.startCharacter))
    }

    private func combine(_ first: String?, _ second: String?) -> String? {
        let merged = (first ?? "") + (second ?? "")
        return merged.isEmpty ? nil : merged
    }

    private func appendToolCalls(_ calls: [ToolCall]) {
        for call in calls {
            appendToolCall(call)
        }
    }

    private func appendToolCall(_ call: ToolCall) {
        let normalized = normalizedToolCall(call)
        toolCalls.append(normalized)
        if orderedOutputEnabled {
            orderedOutputQueue.append(.toolCall(normalized))
        }
    }

    private func normalizedToolCall(_ call: ToolCall) -> ToolCall {
        if let id = call.id, !id.isEmpty, emittedToolCallIDs.insert(id).inserted {
            return call
        }

        return ToolCall(function: call.function, id: generateToolCallID())
    }

    private func generateToolCallID() -> String {
        while true {
            let id = format.generateToolCallID()
            if emittedToolCallIDs.insert(id).inserted {
                return id
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

struct JSONLeadingObjectScanner {
    enum PrefixState {
        case needsMore
        case validObject
        case invalidObject
    }

    let startCharacter: Character

    func evaluatePrefix(in buffer: String) -> PrefixState {
        guard let start = buffer.firstIndex(where: { !$0.isWhitespace }) else {
            return .invalidObject
        }
        return evaluatePrefix(in: buffer, from: start)
    }

    func evaluatePrefix(in buffer: String, from start: String.Index) -> PrefixState {
        var openingIndex = start
        while openingIndex < buffer.endIndex, buffer[openingIndex].isWhitespace {
            openingIndex = buffer.index(after: openingIndex)
        }

        guard openingIndex < buffer.endIndex, buffer[openingIndex] == startCharacter else {
            return .invalidObject
        }

        var index = buffer.index(after: openingIndex)
        while index < buffer.endIndex, buffer[index].isWhitespace {
            index = buffer.index(after: index)
        }

        guard index < buffer.endIndex else {
            return .needsMore
        }

        let firstToken = buffer[index]
        if firstToken == "\"" || firstToken == "}" {
            return .validObject
        }

        return .invalidObject
    }

    /// Splits a buffer that starts with optional whitespace + startCharacter into:
    /// 1) the first complete top-level JSON object
    /// 2) trailing remainder after that object
    func splitLeadingObject(from buffer: String) -> (object: String, trailing: String)? {
        guard let start = buffer.firstIndex(where: { !$0.isWhitespace }),
            buffer[start] == startCharacter
        else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false

        var index = start
        while index < buffer.endIndex {
            let character = buffer[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let object = String(buffer[start ... index])
                        let trailingStart = buffer.index(after: index)
                        let trailing =
                            trailingStart < buffer.endIndex
                            ? String(buffer[trailingStart...])
                            : ""
                        return (object, trailing)
                    }
                default:
                    break
                }
            }

            index = buffer.index(after: index)
        }

        return nil
    }
}
