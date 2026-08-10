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

        /// Tool-call metadata associated with this message.
        public var tool: Tool?

        /// Name of the tool that produced a tool-result message, rendered as the `name`
        /// key. Upstream's `Tool.result(id:)` carries only the id, but a handful of chat
        /// templates read `message.name` on a tool-role message, and the app's text-model
        /// path (`assembledToMLXDict`) has always emitted it — so this keeps the VLM path
        /// rendering the same dictionary as the text path.
        /// Additive and orthogonal to `tool`, so it does not compete with upstream's typed
        /// representation. wangqi modified 2026-03-10 / restored 2026-08-10.
        public var name: String?

        public struct Tool: Sendable {
            fileprivate enum Storage: Sendable {
                case calls([ToolCall])
                case result(id: String)
            }

            fileprivate let storage: Storage

            private init(storage: Storage) {
                self.storage = storage
            }

            /// Tool calls emitted by an assistant message.
            public static func calls(_ calls: [ToolCall]) -> Self {
                Self(storage: .calls(calls))
            }

            /// Id of the assistant tool call answered by a tool message.
            public static func result(id: String) -> Self {
                Self(storage: .result(id: id))
            }

            package var calls: [ToolCall]? {
                guard case .calls(let calls) = storage else { return nil }
                return calls
            }
        }

        public init(
            role: Role, content: String,
            images: [UserInput.Image] = [],
            videos: [UserInput.Video] = [],
            audios: [UserInput.Audio] = [],
            tool: Tool? = nil,
            name: String? = nil
        ) {
            self.role = role
            self.content = content
            self.images = images
            self.videos = videos
            self.audios = audios
            self.tool = tool
            self.name = name
        }

        public static func system(
            _ content: String, images: [UserInput.Image] = [], videos: [UserInput.Video] = []
        ) -> Self {
            Self(role: .system, content: content, images: images, videos: videos)
        }

        public static func assistant(
            _ content: String,
            images: [UserInput.Image] = [],
            videos: [UserInput.Video] = [],
            toolCalls: [ToolCall]? = nil
        ) -> Self {
            Self(
                role: .assistant, content: content, images: images, videos: videos,
                tool: toolCalls.map { .calls($0) })
        }

        public static func user(
            _ content: String,
            images: [UserInput.Image] = [],
            videos: [UserInput.Video] = [],
            audios: [UserInput.Audio] = []
        ) -> Self {
            Self(role: .user, content: content, images: images, videos: videos, audios: audios)
        }

        /// `name` is a fork-local addition — see the `name` property.
        /// wangqi modified 2026-03-10 / restored 2026-08-10.
        public static func tool(_ content: String, id: String? = nil, name: String? = nil) -> Self {
            Self(role: .tool, content: content, tool: id.map { .result(id: $0) }, name: name)
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
        var dictionary: Message = [
            "role": message.role.rawValue,
            "content": message.content,
        ]

        addToolMetadata(to: &dictionary, for: message)

        return dictionary
    }

    /// Adds tool-call metadata from a structured message to a raw message dictionary.
    public func addToolMetadata(to dictionary: inout Message, for message: Chat.Message) {
        switch message.tool?.storage {
        case .calls(let calls):
            dictionary["tool_calls"] = calls.map { toolCall -> [String: any Sendable] in
                var entry: [String: any Sendable] = [
                    "type": "function",
                    "function": [
                        "name": toolCall.function.name,
                        "arguments": toolCall.function.argumentsObject,
                    ] as [String: any Sendable],
                ]
                if let id = toolCall.id {
                    entry["id"] = id
                }
                return entry
            }
        case .result(let id):
            dictionary["tool_call_id"] = id
        case nil:
            break
        }

        // Fork-local: emit the tool name for templates that read `message.name` on a
        // tool-role message. Kept outside the switch so it is independent of how (or
        // whether) `tool` is set. wangqi modified 2026-03-10 / restored 2026-08-10.
        if let name = message.name {
            dictionary["name"] = name
        }
    }

    // wangqi modified 2026-03-10 / 2026-05-15 / 2026-08-10: route the generated messages
    // through MLXLogCollector so the line follows the same on/off / chaining policy as
    // other mlx-swift-lm internal logs. Tool metadata is injected by generate(message:)
    // -> addToolMetadata, so this only maps + logs (no re-injection).
    public func generate(messages: [Chat.Message]) -> [Message] {
        var rawMessages: [Message] = []

        for message in messages {
            let raw = generate(message: message)
            rawMessages.append(raw)
        }

        if MLXLogCollector.shared.hasHandler {
            let summary = rawMessages.map {
                (($0["role"] as? String) ?? "?")
                    + ($0["tool_calls"] != nil ? "+TC" : "")
                    + ($0["tool_call_id"] != nil ? "+TR" : "")
            }.joined(separator: " -> ")
            MLXLogCollector.shared.log("[Chat.generate] \(rawMessages.count) msgs: \(summary)")
        }

        return rawMessages
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

/// Default implementation of ``MessageGenerator`` that produces `role` and
/// `content`, plus `tool_call_id` and `tool_calls` when present.
///
/// ```swift
/// [
///     "role": message.role.rawValue,
///     "content": message.content,
/// ]
/// ```
public struct DefaultMessageGenerator: MessageGenerator {
    public init() {}
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
