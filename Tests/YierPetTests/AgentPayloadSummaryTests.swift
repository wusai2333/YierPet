import Testing
import Foundation
@testable import YierPet

private func payload(_ json: String) -> Data { Data(json.utf8) }

@Suite struct AgentPayloadSummaryTests {
    // MARK: 截断与清洗

    @Test func truncatesAt60Chars() {
        let long = String(repeating: "字", count: 80)
        let out = AgentPayloadSummary.clean(long)
        #expect(out == String(repeating: "字", count: 60) + "…")
    }

    @Test func keepsShortTextUntouched() {
        #expect(AgentPayloadSummary.clean("修复登录 bug") == "修复登录 bug")
    }

    @Test func compressesNewlinesAndWhitespace() {
        #expect(
            AgentPayloadSummary.clean("第一行\n\n第二行\t缩进") == "第一行 第二行 缩进")
    }

    @Test func emojiCountAsSingleChars() {
        let emoji = String(repeating: "🐳", count: 61)
        let out = AgentPayloadSummary.clean(emoji)
        #expect(out == String(repeating: "🐳", count: 60) + "…")
    }

    @Test func emptyAndNilReturnNil() {
        #expect(AgentPayloadSummary.clean(nil) == nil)
        #expect(AgentPayloadSummary.clean("   \n ") == nil)
    }

    // MARK: qwen / qodercli payload

    @Test func notificationMessage() {
        let out = AgentPayloadSummary.summary(
            tool: .qwen, hook: "Notification",
            payload: payload(#"{"message":"Qwen 请求使用 Bash"}"#), cwd: "/w")
        #expect(out == "Qwen 请求使用 Bash")
    }

    @Test func permissionRequestPrefersCommand() {
        let out = AgentPayloadSummary.summary(
            tool: .qwen, hook: "PermissionRequest",
            payload: payload(
                #"{"tool_name":"shell","tool_input":{"command":"ls -la","file_path":"/x"}}"#),
            cwd: "/w")
        #expect(out == "shell：ls -la")
    }

    @Test func permissionRequestFallsBackToFilePath() {
        let out = AgentPayloadSummary.summary(
            tool: .qodercli, hook: "PermissionRequest",
            payload: payload(
                #"{"tool_name":"edit","tool_input":{"file_path":"src/a.swift"}}"#),
            cwd: "/w")
        #expect(out == "edit：src/a.swift")
    }

    @Test func permissionRequestToolNameOnly() {
        let out = AgentPayloadSummary.summary(
            tool: .qwen, hook: "PermissionRequest",
            payload: payload(#"{"tool_name":"mystery"}"#), cwd: "/w")
        #expect(out == "mystery")
    }

    @Test func postToolUseFailureErrorField() {
        let out = AgentPayloadSummary.summary(
            tool: .qwen, hook: "PostToolUseFailure",
            payload: payload(#"{"tool_name":"shell","error":"exit code 127"}"#),
            cwd: "/w")
        #expect(out == "exit code 127")
    }

    // MARK: omp / omo / opencode 携带的 body

    @Test func piStopCarriesText() {
        let out = AgentPayloadSummary.summary(
            tool: .omo, hook: "Stop",
            payload: payload(#"{"text":"已完成重构并通过测试"}"#), cwd: "/w")
        #expect(out == "已完成重构并通过测试")
    }

    @Test func opencodePermissionAndError() {
        #expect(
            AgentPayloadSummary.summary(
                tool: .opencode, hook: "PermissionRequest",
                payload: payload(#"{"permission":"bash: rm *"}"#), cwd: "/w")
                == "bash: rm *")
        #expect(
            AgentPayloadSummary.summary(
                tool: .opencode, hook: "PostToolUseFailure",
                payload: payload(#"{"error":"model overloaded"}"#), cwd: "/w")
                == "model overloaded")
    }

    // MARK: dsh sentinel 携带的 body

    @Test func dshStopCarriesText() {
        let out = AgentPayloadSummary.summary(
            tool: .dsh, hook: "Stop",
            payload: payload(#"{"text":"接入完成，验收通过"}"#), cwd: "/w")
        #expect(out == "接入完成，验收通过")
    }

    @Test func dshFailureAndPermissionAndNotification() {
        #expect(
            AgentPayloadSummary.summary(
                tool: .dsh, hook: "PostToolUseFailure",
                payload: payload(#"{"error":"boom: exit 3"}"#), cwd: "/w")
                == "boom: exit 3")
        #expect(
            AgentPayloadSummary.summary(
                tool: .dsh, hook: "PermissionRequest",
                payload: payload(#"{"message":"bash: needs write"}"#), cwd: "/w")
                == "bash: needs write")
        #expect(
            AgentPayloadSummary.summary(
                tool: .dsh, hook: "Notification",
                payload: payload(#"{"message":"dsh 需要确认"}"#), cwd: "/w")
                == "dsh 需要确认")
    }

    @Test func invalidJSONAndUnknownHookReturnNil() {
        #expect(
            AgentPayloadSummary.summary(
                tool: .qwen, hook: "Notification",
                payload: payload("not json"), cwd: "/w") == nil)
        #expect(
            AgentPayloadSummary.summary(
                tool: .qwen, hook: "UserPromptSubmit",
                payload: payload(#"{"prompt":"hi"}"#), cwd: "/w") == nil)
        #expect(
            AgentPayloadSummary.summary(
                tool: .qwen, hook: "Notification", payload: nil, cwd: "/w")
                == nil)
    }

    // MARK: transcript 尾部读取

    @Test func readsLastAssistantTextFromTranscript() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"修个 bug"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"我先看一下代码"},{"type":"text","text":"，找到了"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"继续"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"修好了，加了测试"}]}}"#,
            #"{"type":"system","subtype":"stop_hook"}"#,
        ]
        try lines.joined(separator: "\n").write(
            to: file, atomically: true, encoding: .utf8)
        let out = AgentPayloadSummary.lastAssistantText(
            inTranscript: file.path)
        #expect(out == "我先看一下代码，找到了" || out == "修好了，加了测试")
        #expect(out == "修好了，加了测试")
    }

    @Test func transcriptEdgeCases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 无助手消息
        let noAssistant = dir.appendingPathComponent("a.jsonl")
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#
            .write(to: noAssistant, atomically: true, encoding: .utf8)
        #expect(
            AgentPayloadSummary.lastAssistantText(inTranscript: noAssistant.path)
                == nil)
        // 空文件
        let empty = dir.appendingPathComponent("b.jsonl")
        try "".write(to: empty, atomically: true, encoding: .utf8)
        #expect(AgentPayloadSummary.lastAssistantText(inTranscript: empty.path) == nil)
        // 文件不存在
        #expect(
            AgentPayloadSummary.lastAssistantText(
                inTranscript: dir.appendingPathComponent("nope.jsonl").path)
                == nil)
        // 尾部窗口：大文件只读尾部仍能找到最后的助手消息
        let big = dir.appendingPathComponent("c.jsonl")
        var content = ""
        for i in 0..<2000 {
            content += #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"早期消息 \#(i) 填充内容让文件变大一些"}]}}"# + "\n"
        }
        content += #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"最后一条"}]}}"#
        try content.write(to: big, atomically: true, encoding: .utf8)
        #expect(
            AgentPayloadSummary.lastAssistantText(
                inTranscript: big.path, tailBytes: 65536) == "最后一条")
    }

    @Test func stopHookReadsTranscriptFromPayload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"干完了"}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let json = #"{"transcript_path":"\#(file.path)"}"#
        let out = AgentPayloadSummary.summary(
            tool: .qwen, hook: "Stop", payload: payload(json), cwd: "/w")
        #expect(out == "干完了")
    }
}

    // MARK: 限流 / 服务端错误提醒

    @Test func stopFailureCarriesApiError() {
        let out = AgentPayloadSummary.summary(
            tool: .qwen, hook: "StopFailure",
            payload: payload(
                #"{"error":"RATE_LIMIT","error_details":"429 rate limit exceeded, retrying later","last_assistant_message":"..."}"#),
            cwd: "/w")
        #expect(out == "429 rate limit exceeded, retrying later")
        let fallback = AgentPayloadSummary.summary(
            tool: .qodercli, hook: "StopFailure",
            payload: payload(#"{"error":"SERVER_ERROR"}"#), cwd: "/w")
        #expect(fallback == "SERVER_ERROR")
    }

    @Test func piToolFailureSummary() {
        #expect(
            AgentPayloadSummary.summary(
                tool: .omp, hook: "PostToolUseFailure",
                payload: payload(#"{"error":"模型报错：过载，30s 后重试 (1/3)"}"#),
                cwd: "/w")
                == "模型报错：过载，30s 后重试 (1/3)")
        #expect(
            AgentPayloadSummary.summary(
                tool: .omo, hook: "PostToolUseFailure",
                payload: payload(#"{"error":"upstream 503"}"#), cwd: "/w")
                == "upstream 503")
    }
