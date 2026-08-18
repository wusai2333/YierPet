# 气泡内容摘要 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agent 哨兵的三种提醒（等确认/完成/报错）气泡附带会话内容摘要：从钩子 payload / transcript 文件尽力提取，60 字截断，提取失败静默降级为现有无摘要文案。

**Architecture:** 现有事件链路加"内容"维度——`AgentServer` 不再丢弃 POST body（2MB 上限，超限交付 nil payload 而非丢事件），新纯函数提取器 `AgentPayloadSummary` 按 tool+hook 解析摘要（qwen/qodercli 的 Stop 读 transcript JSONL 尾部），`AgentCenter` 把摘要经 `AgentAlert.detail` 拼进气泡第二行『』。omp/omo/opencode 的内嵌 TS 源码升级为在 POST body 里携带助手文本/权限描述。

**Tech Stack:** Swift（AppKit + Foundation，零第三方依赖）、Swift Testing、TypeScript（内嵌插件/扩展源码，bun 校验语法）。

**Spec:** `docs/superpowers/specs/2026-08-19-bubble-content-summary-design.md`（commit b9f66a0）。

## Global Constraints

- 平台 macOS 13+，纯系统框架，禁止第三方依赖；Swift 5 语言模式（Package.swift 已配）。
- 跑测试命令固定为 `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`，以输出 `Test run with N tests`（N>0）为准；裸 `swift test` 会静默 0 测试。
- 钩子/插件绝不阻塞 agent：TS 侧 POST 仍 1s 超时 + catch 吞错；body 变大不改变该承诺。
- 摘要提取尽力而为：任何解析失败 → 无摘要，提醒本身不受影响。
- 全部逻辑主线程；transcript 只读文件尾部 64KB。
- 提交信息风格：feat:/fix:/docs: 前缀 + 中文描述。
- 不得为测试改动真实用户配置（~/.qwen、~/.omo 等）；TS 常量更新后真实重装留给用户点菜单。

---

### Task 1: AgentPayloadSummary 纯提取器（TDD）

**Files:**
- Create: `Sources/YierPet/AgentPayloadSummary.swift`
- Test: `Tests/YierPetTests/AgentPayloadSummaryTests.swift`

**Interfaces:**
- Consumes: Task 无关（既有 `AgentTool`）
- Produces: `AgentPayloadSummary.summary(tool:hook:payload:cwd:) -> String?`、`lastAssistantText(inTranscript:tailBytes:) -> String?`、`clean(_:) -> String?`（internal，供测试）

- [ ] **Step 1: 写失败测试**

创建 `Tests/YierPetTests/AgentPayloadSummaryTests.swift`（Swift Testing 风格照抄现有测试文件）：

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter AgentPayloadSummaryTests 2>&1 | tail -5`
Expected: 编译失败，`AgentPayloadSummary` 未定义。

- [ ] **Step 3: 实现 AgentPayloadSummary**

创建 `Sources/YierPet/AgentPayloadSummary.swift`：

```swift
import Foundation

/// Extracts a short human-readable summary from agent hook payloads.
/// Pure and best-effort: returns nil when nothing sensible is found, so
/// reminders always fire with or without a summary.
enum AgentPayloadSummary {
    static let maxChars = 60
    private static let transcriptTailBytes = 65536
    private static let toolInputKeys = [
        "command", "script", "file_path", "path", "query",
    ]

    /// Main entry: summarizes an event payload for the given tool/hook.
    static func summary(
        tool: AgentTool, hook: String, payload: Data?, cwd: String
    ) -> String? {
        guard let payload, !payload.isEmpty else { return nil }
        let raw: String?
        switch (tool, hook) {
        case (.qwen, "Notification"), (.qodercli, "Notification"):
            raw = stringValue(in: payload, key: "message")
        case (.qwen, "PermissionRequest"), (.qodercli, "PermissionRequest"):
            raw = permissionSummary(payload)
        case (.qwen, "Stop"), (.qodercli, "Stop"):
            raw = transcriptSummary(payload)
        case (.qwen, "PostToolUseFailure"), (.qodercli, "PostToolUseFailure"):
            raw = firstString(payload, keys: ["error", "message", "tool_response"])
        case (.omp, "Stop"), (.omo, "Stop"), (.opencode, "Stop"):
            raw = stringValue(in: payload, key: "text")
        case (.opencode, "PermissionRequest"):
            raw = stringValue(in: payload, key: "permission")
        case (.opencode, "PostToolUseFailure"):
            raw = stringValue(in: payload, key: "error")
        default:
            return nil
        }
        return clean(raw)
    }

    /// Compresses whitespace/newlines, trims, truncates to maxChars.
    static func clean(_ string: String?) -> String? {
        guard let string else { return nil }
        let flattened = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > maxChars else { return flattened }
        return String(flattened.prefix(maxChars)) + "…"
    }

    /// Reads the tail of a JSONL transcript and returns the last
    /// assistant text. Best-effort: any parse/read problem returns nil.
    static func lastAssistantText(
        inTranscript path: String, tailBytes: Int = transcriptTailBytes
    ) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(
                      with: lineData)) as? [String: Any]
            else { continue }
            if let found = assistantText(in: object) { return found }
        }
        return nil
    }

    // MARK: - Internals

    private static func transcriptSummary(_ payload: Data) -> String? {
        guard let path = stringValue(in: payload, key: "transcript_path")
        else { return nil }
        return lastAssistantText(inTranscript: path)
    }

    private static func permissionSummary(_ payload: Data) -> String? {
        guard let object = jsonObject(payload) else { return nil }
        guard let toolName = object["tool_name"] as? String,
              !toolName.isEmpty
        else { return object["message"] as? String }
        let input = object["tool_input"] as? [String: Any]
        for key in toolInputKeys {
            if let value = input?[key] as? String, !value.isEmpty {
                return "\(toolName)：\(value)"
            }
        }
        return toolName
    }

    /// Extracts assistant text from one transcript record (CC/qwen shape:
    /// {"message":{"role":"assistant","content":[...]}}) or a bare
    /// pi-style message object ({"role":"assistant","content":...}).
    private static func assistantText(in object: [String: Any]) -> String? {
        if let message = object["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            return contentText(message["content"])
        }
        if (object["role"] as? String) == "assistant" {
            return contentText(object["content"])
        }
        return nil
    }

    private static func contentText(_ content: Any?) -> String? {
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringValue(in payload: Data, key: String) -> String? {
        jsonObject(payload)?[key] as? String
    }

    private static func firstString(_ payload: Data, keys: [String]) -> String? {
        guard let object = jsonObject(payload) else { return nil }
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks 2>&1 | tail -3`
Expected: 全部测试 PASS（22 旧 + 本任务新增），输出出现 `Test run with N tests`。

- [ ] **Step 5: Commit**

```bash
git add Sources/YierPet/AgentPayloadSummary.swift Tests/YierPetTests/AgentPayloadSummaryTests.swift
git commit -m "feat: Agent 哨兵——气泡摘要提取器（payload/transcript 解析，60 字截断）"
```

---

### Task 2: payload 管道（AgentServer 保留 body + 状态机携带 detail）

**Files:**
- Modify: `Sources/YierPet/AgentServer.swift`
- Modify: `Sources/YierPet/AgentSessionStore.swift`
- Test: `Tests/YierPetTests/AgentServerTests.swift`（追加）
- Test: `Tests/YierPetTests/AgentSessionStoreTests.swift`（追加）

**Interfaces:**
- Consumes: Task 1 `AgentPayloadSummary`（本任务不改它）
- Produces: `AgentEvent.payload: Data?`；`AgentAlert.detail: String?`；`AgentSessionStore.apply(_:detail:at:)`（detail 默认 nil，旧调用兼容）；`AgentServer` 三态解析（incomplete/invalid/event）与 2MB 上限

- [ ] **Step 1: 写失败测试（先加测试）**

`AgentServerTests.swift` 追加两个测试（沿用文件里现有的启动/等待模式）：

```swift
    @Test func deliversBodyAsPayload() throws {
        let server = AgentServer()
        server.queue = DispatchQueue(label: "agent-server-test-1")
        var received: AgentEvent?
        server.onEvent = { received = $0 }
        server.start()
        defer { server.stop() }
        let readyDeadline = Date().addingTimeInterval(5)
        while server.endpointString == nil && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let endpoint = server.endpointString,
              let url = URL(string: endpoint)
        else { return Issue.record("server never became ready") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("qwen", forHTTPHeaderField: "X-YierPet-Tool")
        request.setValue("Notification", forHTTPHeaderField: "X-YierPet-Hook")
        request.setValue("/w/proj", forHTTPHeaderField: "X-YierPet-Cwd")
        request.httpBody = Data(#"{"message":"hi"}"#.utf8)
        URLSession.shared.dataTask(with: request).resume()
        let deadline = Date().addingTimeInterval(5)
        while received == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(received?.payload == Data(#"{"message":"hi"}"#.utf8))
    }

    @Test func oversizedBodyDeliversEventWithoutPayload() throws {
        let server = AgentServer()
        server.queue = DispatchQueue(label: "agent-server-test-2")
        var received: AgentEvent?
        server.onEvent = { received = $0 }
        server.start()
        defer { server.stop() }
        let readyDeadline = Date().addingTimeInterval(5)
        while server.endpointString == nil && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let endpoint = server.endpointString,
              let url = URL(string: endpoint)
        else { return Issue.record("server never became ready") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("qwen", forHTTPHeaderField: "X-YierPet-Tool")
        request.setValue("Stop", forHTTPHeaderField: "X-YierPet-Hook")
        request.setValue("/w/proj", forHTTPHeaderField: "X-YierPet-Cwd")
        request.httpBody = Data(repeating: 65, count: 3 * 1024 * 1024)
        URLSession.shared.dataTask(with: request).resume()
        let deadline = Date().addingTimeInterval(10)
        while received == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(received?.hook == "Stop")
        #expect(received?.payload == nil)
    }
```

`AgentSessionStoreTests.swift` 追加：

```swift
    @Test func detailFlowsToAlertsAndNudges() {
        var store = AgentSessionStore()
        // 心跳携带内容：不提醒，但记住摘要
        _ = store.apply(
            event("PostToolUse"),
            detail: "中间过程摘要", at: t0)
        // 完成提醒带上最后的摘要
        let done = store.apply(event("Stop"), detail: nil, at: t0 + 5)
        #expect(done?.kind == .done)
        #expect(done?.detail == "中间过程摘要")
        // 等确认自带摘要；轻提醒复用
        let confirm = store.apply(
            event("PermissionRequest"), detail: "要执行 ls", at: t0 + 10)
        #expect(confirm?.detail == "要执行 ls")
        let nudges = store.dueNudges(at: t0 + 10 + 121)
        #expect(nudges.count == 1)
        #expect(nudges.first?.detail == "要执行 ls")
    }
```

（`event(_:)` 助手与 `t0` 沿用该测试文件现有定义。）

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks 2>&1 | grep -E 'error|failed' | head -8`
Expected: 编译错误（`payload`/`detail` 成员不存在、apply 签名不匹配）。

- [ ] **Step 3: 改 AgentSessionStore**

`AgentEvent` 加字段（默认 nil，既有构造调用兼容）：

```swift
struct AgentEvent {
    let tool: AgentTool
    let hook: String
    let cwd: String
    var payload: Data? = nil
}
```

`AgentAlert` 加 `detail`：

```swift
struct AgentAlert {
    let kind: AgentAlertKind
    let tool: AgentTool
    let project: String
    var detail: String? = nil
}
```

`Session` 加 `var lastDetail: String?`（初始 nil，两处构造同步）。

`apply` 签名与逻辑（detail 默认 nil）：

```swift
    mutating func apply(
        _ event: AgentEvent, detail: String? = nil, at now: Date
    ) -> AgentAlert? {
        let key = Self.key(tool: event.tool, cwd: event.cwd)

        if event.hook == "SessionEnd" {
            sessions[key] = nil
            return nil
        }

        var session = sessions[key] ?? Session(...)   // 现有构造
        let previous = session.state
        session.lastEvent = now
        if let detail, !detail.isEmpty { session.lastDetail = detail }
        var alert: AgentAlert?

        // ……现有 switch 不变，各 alert 构造处补 detail：
        // needsConfirm：detail 取本次 detail ?? session.lastDetail
        // done / error：同上
```

三处 `AgentAlert(...)` 构造统一追加 `detail: detail ?? session.lastDetail`。

`dueNudges` 的 alert 追加 `detail: session.lastDetail`。

- [ ] **Step 4: 改 AgentServer（三态解析 + body 交付 + 2MB 上限）**

要点（对照现有 `parse`/`receive` 改写）：

```swift
    private static let maxBodyBytes = 2 * 1024 * 1024

    private enum ParseResult {
        case incomplete
        case invalid
        case event(AgentEvent)
    }
```

`parse(_ data: Data) -> ParseResult`：
- 未找到 `\r\n\r\n` → `.incomplete`
- 请求行非 POST → `.invalid`
- header 缺 `x-yierpet-tool`（可映射到 AgentTool）或 `x-yierpet-hook` → `.invalid`
- `content-length > maxBodyBytes` → 直接 `.event(AgentEvent(tool:hook:cwd:payload:nil))`（不等 body，丢摘要不丢提醒）
- body 未收全 → `.incomplete`；收全 → `.event`，payload 取 `Data(bodyText.utf8.prefix(contentLength))`

`receive` 按三态分派：`.event` → onEvent + 200；`.invalid` → 400；`.incomplete` → 出错/结束/缓冲超 `maxBodyBytes + 4096` 时 400，否则继续收。

- [ ] **Step 5: 运行全部测试确认通过**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks 2>&1 | tail -3`
Expected: 全绿，`Test run with N tests`（N = 上一任务数 + 3）。

- [ ] **Step 6: Commit**

```bash
git add Sources/YierPet/AgentServer.swift Sources/YierPet/AgentSessionStore.swift Tests/YierPetTests/AgentServerTests.swift Tests/YierPetTests/AgentSessionStoreTests.swift
git commit -m "feat: Agent 哨兵——事件携带 payload（2MB 上限，超限丢摘要不丢提醒）与会话 detail"
```

---

### Task 3: AgentCenter 拼接摘要进气泡

**Files:**
- Modify: `Sources/YierPet/AgentCenter.swift`
- Test: `Tests/YierPetTests/AgentCenterTests.swift`（追加）

**Interfaces:**
- Consumes: Task 1 `AgentPayloadSummary.summary`；Task 2 `apply(_:detail:at:)`、`AgentAlert.detail`
- Produces: 气泡文案带『』摘要行；`AgentCenter.message(for:)` 行为更新

- [ ] **Step 1: 写失败测试**

`AgentCenterTests.swift` 追加：

```swift
    @Test func messageIncludesDetailLine() {
        let withDetail = AgentCenter.message(
            for: AgentAlert(
                kind: .needsConfirm, tool: .qwen, project: "proj",
                detail: "shell：ls -la"))
        #expect(withDetail.contains("『shell：ls -la』"))
        #expect(withDetail.contains("\n"))
        let without = AgentCenter.message(
            for: AgentAlert(kind: .done, tool: .qwen, project: "proj"))
        #expect(!without.contains("『"))
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter AgentCenterTests 2>&1 | tail -5`
Expected: messageIncludesDetailLine 失败（现实现不带 『』）。

- [ ] **Step 3: 改 AgentCenter**

`handle(_:)`：

```swift
    private func handle(_ event: AgentEvent) {
        guard isEnabled, isEnabled(event.tool) else { return }
        let detail = AgentPayloadSummary.summary(
            tool: event.tool, hook: event.hook, payload: event.payload,
            cwd: event.cwd)
        if let alert = store.apply(event, detail: detail, at: Date()) {
            fire(alert)
        }
    }
```

`message(for:)`：

```swift
    static func message(for alert: AgentAlert) -> String {
        let template = messages[alert.kind]?.randomElement() ?? ""
        var text = template
            .replacingOccurrences(of: "{tool}", with: alert.tool.rawValue)
            .replacingOccurrences(of: "{proj}", with: alert.project)
        if let detail = alert.detail, !detail.isEmpty {
            text += "\n『\(detail)』"
        }
        return text
    }
```

- [ ] **Step 4: 运行全部测试 + 构建 + 冒烟**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks 2>&1 | tail -3 && ./build.sh`
冒烟：`open build/YierPet.app`，3 秒后 `pgrep -x YierPet` 确认存活，`killall YierPet`。

- [ ] **Step 5: Commit**

```bash
git add Sources/YierPet/AgentCenter.swift Tests/YierPetTests/AgentCenterTests.swift
git commit -m "feat: Agent 哨兵——气泡附带会话摘要（『』第二行）"
```

---

### Task 4: TS 插件/扩展源码升级 + README

**Files:**
- Modify: `Sources/YierPet/AgentHookInstaller.swift`（三段 TS 常量）
- Modify: `README.md`

**Interfaces:**
- Consumes: 既有安装器骨架；spec §6 的 body 约定（omp/omo：Stop 带 `{text}`；opencode：PermissionRequest 带 `{permission}`、Stop 带 `{text}`、PostToolUseFailure 带 `{error}`）
- Produces: 更新后的三段内嵌 TS；README 一行补充

- [ ] **Step 1: 更新 ompExtensionSource 与 omoExtensionSource**

两段做相同修改（仅 `X-YierPet-Tool` 值不同，现状分别为 'omp'/'omo'）：

- `post` 增加 extra 参数：`function post(hookEventName: string, extra: Record<string, unknown> = {}): void`，`body: JSON.stringify(extra)`
- 模块级 `let lastAssistantText = ''`
- 新增助手文本提取（与 orca-agent-status.ts 的 extractAssistantText 同款）：

```ts
    function extractAssistantText(message): string {
      const content = message?.content
      if (typeof content === 'string') return content
      if (!Array.isArray(content)) return ''
      return content
        .filter((b) => b?.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text)
        .join(' ')
        .trim()
    }
```

- handler 调整：

```ts
    export default function (pi): void {
      pi.on('agent_start', () => {
        lastAssistantText = ''
        post('UserPromptSubmit')
      })
      pi.on('tool_execution_start', () => post('PostToolUse'))
      pi.on('tool_execution_end', () => post('PostToolUse'))
      pi.on('message_end', (event) => {
        if (event?.message?.role !== 'assistant') return
        const text = extractAssistantText(event.message)
        if (text) lastAssistantText = text
        post('PostToolUse')
      })
      pi.on('agent_settled', () => post('Stop', { text: lastAssistantText }))
      pi.on('agent_end', () => post('Stop', { text: lastAssistantText }))
    }
```

- [ ] **Step 2: 更新 opencodePluginSource**

- `post` 增加 extra 参数（同上，body 改 `JSON.stringify(extra)`）
- 模块级 `let lastAssistantText = ''`
- 助手文本跟踪（尽力兼容两种事件形状，role 非 assistant 一律跳过）：

```ts
    function trackAssistantText(event: { type: string; properties?: any }): void {
      const props = event?.properties ?? {}
      const message = props.message ?? props.info
      if (message && message.role && message.role !== 'assistant') return
      const parts: any[] = Array.isArray(props.parts)
        ? props.parts
        : props.part ? [props.part] : []
      const text = parts
        .filter((p) => p?.type === 'text' && typeof p.text === 'string')
        .map((p) => p.text)
        .join(' ')
        .trim()
      if (text) lastAssistantText = text
    }
```

- event switch 更新：

```ts
        event: async ({ event }: { event: any }) => {
          switch (event?.type) {
            case "session.idle":
              post("Stop", directory, { text: lastAssistantText });
              lastAssistantText = "";
              break;
            case "session.error": {
              const err = event?.properties?.error;
              const text = typeof err === "string"
                ? err : (err?.message ?? "");
              post("PostToolUseFailure", directory, { error: text });
              break;
            }
            case "message.updated":
            case "message.part.updated":
              trackAssistantText(event);
              post("PostToolUse", directory);
              break;
          }
        },
        "permission.ask": async (input: any) => {
          const desc = `${input?.type ?? "permission"}${
            input?.pattern ? ": " + input.pattern : ""}`;
          post("PermissionRequest", directory, { permission: desc });
        },
```

- [ ] **Step 3: bun 语法校验三段 TS**

从 Swift 源码提取三段常量到临时文件（python 正则，参考既有做法），逐一 `bun build <file>`（输出转译结果即通过）。三段都必须过。

- [ ] **Step 4: README 补充**

Agent 哨兵小节的能力表加一行：

```markdown
| 内容摘要 | 提醒气泡附带会话摘要：等确认显示要确认什么、完成显示 agent 最后回复片段、报错显示错误信息；截取原文前 60 字，仅本机处理 |
```

- [ ] **Step 5: 全量测试 + 构建**

Run: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks 2>&1 | tail -3 && ./build.sh`
Expected: 全绿 + 构建成功。

- [ ] **Step 6: Commit**

```bash
git add Sources/YierPet/AgentHookInstaller.swift README.md
git commit -m "feat: Agent 哨兵——插件/扩展携带会话内容，README 补充摘要说明"
```

---

### 收尾：用户操作 + 人工 E2E（控制器协调，非子代理步骤）

1. 用户重新点一次"安装 Agent 钩子"（幂等覆盖三个 TS 文件）
2. `printf '{"message":"Qwen 请求执行 rm -rf /tmp/x"}' | ~/.yierpet/hook.sh qwen Notification` → 气泡第二行应出现『Qwen 请求执行 rm -rf /tmp/x』
3. qwen 实跑一轮 → 完成气泡应带最后回复摘要
4. omo `-p` 实跑一轮 → 完成气泡带摘要
5. opencode 实跑一轮 → 完成气泡带摘要（若为空，按实际事件形状微调 trackAssistantText）

## Self-Review 记录

- **Spec 覆盖**：§3 摘要来源表 → Task 1（qwen/qodercli/omp/omo/opencode 各分支）+ Task 4（TS 携带内容）；§4 展示格式/截断/lastDetail → Task 1 clean + Task 2 detail + Task 3 『』拼接；§5 AgentServer 调整 → Task 2；§6 插件源码 → Task 4；§7 改动清单逐条对应；§8 错误处理 → Task 1 尽力而为 + Task 2 超限交付；§9 测试 → Task 1-3 单测 + 收尾 E2E。
- **占位符扫描**：opencode 事件形状为尽力兼容实现且收尾 E2E 第 5 步明确"若为空按实际形状微调"——这是运行时验证项，非模糊占位。
- **类型一致性**：`summary(tool:hook:payload:cwd:)`（Task 1）→ `handle` 调用（Task 3）；`apply(_:detail:at:)` 默认参数保证 Task 1 前写的测试不需改；`AgentAlert.detail` 在 Task 2 定义、Task 1 测试不引用、Task 3 消费。
