// Copyright © 2025 Apple Inc.

public enum Chat {
    public struct Message {
        /// The role of the message sender.
        public var role: Role

        /// The content of the message.
        public var content: String

        /// Array of image data associated with the message.
        public var images: [UserInput.Image]

        /// Array of video data associated with the message.
        public var videos: [UserInput.Video]

        /// Array of audio data associated with the message.
        public var audios: [UserInput.Audio]

        // wangqi modified 2026-03-10: Add optional tool call fields to support multi-turn tool calling
        // via Chat.Message API. toolCalls enables assistant messages with tool call requests;
        // toolCallId/name enable tool result messages. All fields default to nil for backward compatibility.
        /// Tool calls requested by the assistant (for assistant messages with tool calls).
        public var toolCalls: [[String: any Sendable]]?

        /// The tool call ID this message is responding to (for tool result messages).
        public var toolCallId: String?

        /// The name of the tool (for tool result messages).
        public var name: String?

        public init(
            role: Role, content: String,
            images: [UserInput.Image] = [],
            videos: [UserInput.Video] = [],
            audios: [UserInput.Audio] = [],
            toolCalls: [[String: any Sendable]]? = nil,
            toolCallId: String? = nil,
            name: String? = nil
        ) {
            self.role = role
            self.content = content
            self.images = images
            self.videos = videos
            self.audios = audios
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
            self.name = name
        }

        public static func system(
            _ content: String, images: [UserInput.Image] = [], videos: [UserInput.Video] = []
        ) -> Self {
            Self(role: .system, content: content, images: images, videos: videos)
        }

        // wangqi modified 2026-03-10: Added toolCalls parameter so assistant messages can carry tool call requests.
        public static func assistant(
            _ content: String, images: [UserInput.Image] = [], videos: [UserInput.Video] = [],
            toolCalls: [[String: any Sendable]]? = nil
        ) -> Self {
            Self(role: .assistant, content: content, images: images, videos: videos, toolCalls: toolCalls)
        }

        public static func user(
            _ content: String,
            images: [UserInput.Image] = [],
            videos: [UserInput.Video] = [],
            audios: [UserInput.Audio] = []
        ) -> Self {
            Self(role: .user, content: content, images: images, videos: videos, audios: audios)
        }

        // wangqi modified 2026-03-10: Added toolCallId/name parameters to tool() so tool result messages
        // carry the required metadata for multi-turn tool call history replay.
        public static func tool(
            _ content: String, toolCallId: String? = nil, name: String? = nil
        ) -> Self {
            Self(role: .tool, content: content, toolCallId: toolCallId, name: name)
        }

        public enum Role: String, Sendable {
            case user
            case assistant
            case system
            case tool
        }
    }
}

/// Protocol for something that can convert structured
/// ``Chat/Message`` into model specific ``Message``
/// (raw dictionary) format.
///
/// Typically this is owned and used by a ``UserInputProcessor``:
///
/// ```swift
/// public func prepare(input: UserInput) async throws -> LMInput {
///     let messages = Qwen2VLMessageGenerator().generate(from: input)
///     ...
/// ```
public protocol MessageGenerator: Sendable {

    /// Generates messages from the input.
    func generate(from input: UserInput) -> [Message]

    /// Returns array of `[String: any Sendable]` aka ``Message``
    func generate(messages: [Chat.Message]) -> [Message]

    /// Returns `[String: any Sendable]`, aka ``Message``.
    func generate(message: Chat.Message) -> Message
}

extension MessageGenerator {

    public func generate(message: Chat.Message) -> Message {
        [
            "role": message.role.rawValue,
            "content": message.content,
        ]
    }

    // wangqi modified 2026-03-10: Override generate(messages:) default implementation to centrally inject
    // tool call fields (tool_calls, tool_call_id, name) after each model-specific generate(message:) call.
    // This avoids duplicating tool field injection in every VLM/LLM MessageGenerator subclass.
    public func generate(messages: [Chat.Message]) -> [Message] {
        let result = messages.map { message in
            var raw = generate(message: message)
            // Inject tool-related fields that model-specific generators don't handle
            if let toolCalls = message.toolCalls {
                raw["tool_calls"] = toolCalls
            }
            if let toolCallId = message.toolCallId {
                raw["tool_call_id"] = toolCallId
            }
            if let name = message.name {
                raw["name"] = name
            }
            return raw
        }
        // Route through MLXLogCollector so the line follows the same on/off / chaining policy
        // as other mlx-swift-lm internal logs — wangqi modified 2026-05-15
        if MLXLogCollector.shared.hasHandler {
            MLXLogCollector.shared.log("[Chat.generate] \(result.count) msgs: \(result.map { (($0["role"] as? String) ?? "?") + ($0["tool_calls"] != nil ? "+TC" : "") + ($0["tool_call_id"] != nil ? "+TR" : "") }.joined(separator: " -> "))")
        }
        return result
    }

    public func generate(from input: UserInput) -> [Message] {
        switch input.prompt {
        case .text(let text):
            generate(messages: [.user(text)])
        case .messages(let messages):
            messages
        case .chat(let messages):
            generate(messages: messages)
        }
    }
}

/// Default implementation of ``MessageGenerator`` that produces a
/// `role` and `content`.
///
/// ```swift
/// [
///     "role": message.role.rawValue,
///     "content": message.content,
/// ]
/// ```
public struct DefaultMessageGenerator: MessageGenerator {
    public init() {}

    public func generate(message: Chat.Message) -> Message {
        [
            "role": message.role.rawValue,
            "content": message.content,
        ]
    }
}

/// Implementation of ``MessageGenerator`` that produces a
/// `role` and `content` but omits `system` roles.
///
/// ```swift
/// [
///     "role": message.role.rawValue,
///     "content": message.content,
/// ]
/// ```
public struct NoSystemMessageGenerator: MessageGenerator {
    public init() {}

    public func generate(messages: [Chat.Message]) -> [Message] {
        messages
            .filter { $0.role != .system }
            .map { generate(message: $0) }
    }
}
