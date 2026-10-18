// Copyright © 2026 Apple Inc.

import Foundation
import Testing

@testable import MLXLMCommon

// wangqi modified 2026-10-18
struct MiniCPM5FunctionParserTests {

    private static let tools: [[String: any Sendable]] = [
        [
            "type": "function",
            "function": [
                "name": "get_date",
                "parameters": [
                    "type": "object",
                    "properties": ["offset": ["type": "integer"] as [String: any Sendable]],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    ]

    /// MiniCPM5-1B-4bit's real output for the regression probe (mlx-swift-lm dae0d049d).
    private static let recorded =
        "<think>\nThe user wants the date 10 days later. I should call the get_date function with an offset of 10 days.\n</think>\n\n<function name=\"get_date\"><param name=\"offset\">10</param></function>"

    @Test("The MiniCPM5 template overrides the Llama 3 vocabulary guess")
    func templateOverridesLlama3Guess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minicpm5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"""
        {"chat_template": "Call a function using:\n<function name=\"function-name\"><param name=\"param-name\">value</param></function>"}
        """#.write(
            to: directory.appendingPathComponent("tokenizer_config.json"), atomically: true,
            encoding: .utf8)

        #expect(
            ToolCallFormat.resolved(forTokenizerDirectory: directory, modelFormat: .llama3)
                == .minicpm5)
    }

    @Test("Streamed in small chunks, the recorded output yields one call and no raw syntax")
    func streamedRecordedOutputYieldsOneCall() throws {
        let processor = ToolCallProcessor(format: .minicpm5, tools: Self.tools)
        var text = ""
        var index = Self.recorded.startIndex
        while index < Self.recorded.endIndex {
            let next =
                Self.recorded.index(index, offsetBy: 3, limitedBy: Self.recorded.endIndex)
                ?? Self.recorded.endIndex
            text += processor.processChunk(String(Self.recorded[index ..< next])) ?? ""
            index = next
        }
        text += processor.processEOS(returnBufferedText: true) ?? ""

        let calls = processor.drainToolCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "get_date")
        #expect(call.function.arguments == ["offset": .int(10)])
        #expect(!text.contains("<function"))
        #expect(text.contains("get_date function"))
    }

    @Test("A CDATA value is unwrapped and multi-line text is kept")
    func cdataValueIsUnwrapped() throws {
        let call = try #require(
            MiniCPM5FunctionParser().parse(
                content:
                    "<function name=\"write_note\"><param name=\"body\"><![CDATA[line one\nline two]]></param></function>",
                tools: nil))
        #expect(call.function.name == "write_note")
        #expect(call.function.arguments == ["body": .string("line one\nline two")])
    }

    @Test("Content split on the start tag still parses")
    func contentWithoutStartTagParses() throws {
        let calls = MiniCPM5FunctionParser().parseEOS(
            "<function name=\"get_date\"><param name=\"offset\">3</param></function>",
            tools: Self.tools)
        #expect(calls.count == 1)
        #expect(calls.first?.function.arguments == ["offset": .int(3)])
    }

    @Test("A call without a name is rejected")
    func missingNameIsRejected() {
        #expect(
            MiniCPM5FunctionParser().parse(
                content: "<function name=\"\"><param name=\"offset\">1</param></function>",
                tools: nil) == nil)
    }
}
