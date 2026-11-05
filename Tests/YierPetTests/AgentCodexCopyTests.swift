import Foundation
import Testing
@testable import YierPet

// codex 专属文案 + codex「Stop 里混着报错」的判定。
// 事实依据（codex 0.166，本机 ~/.codex/sessions 实测 135 条 task_complete / 13 条带 error）：
// stop 钩子载荷没有 error 字段，失败时 last_assistant_message 为 null，
// 错误原文只存在于 transcript 的 event_msg/task_complete.payload.error.message。

extension AgentAlertKind: Equatable {}

/// 用 JSONSerialization 拼夹具：路径含 `/` 无所谓，但绝不能手嵌未转义的引号。
private func codexPayload(transcript: String?, message: String? = nil) -> Data {
    let object: [String: Any] = [
        "hook_event_name": "Stop",
        "last_assistant_message": message ?? NSNull(),
        "transcript_path": transcript ?? NSNull(),
    ]
    return (try! JSONSerialization.data(withJSONObject: object))
}

/// 必须写在临时目录下的子目录里：直接落 temporaryDirectory 根时，
/// swift test 宿主里 FileHandle 读不到（实测既有通过用例都是这么做的）。
private func writeTranscript(
    _ lines: [String]
) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("rollout.jsonl")
    try lines.joined(separator: "\n")
        .write(to: file, atomically: true, encoding: .utf8)
    return file.path
}

// 用户机器上真实的一条失败记录（内网 token-optimizer 代理 502）
private let realErrorLine =
    #"{"timestamp":"2026-11-04T10:43:24.282Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"01a1a627","last_agent_message":null,"error":{"message":"unexpected status 502 Bad Gateway: token-optimizer proxy: upstream request failed: self-signed certificate in certificate chain","codex_error_info":{"http_connection_failed":{"http_status_code":502}}}}}"#

private let realDoneLine =
    #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"01a1a628","last_agent_message":"改完了，测试都过了"}}"#

@Test func codexStopWithTranscriptErrorIsFailure() throws {
    let path = try writeTranscript([
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        realErrorLine,
    ])
    defer { try? FileManager.default.removeItem(
        atPath: (path as NSString).deletingLastPathComponent) }

    let parsed = AgentPayloadSummary.codexStop(codexPayload(transcript: path))
    #expect(parsed.isFailure == true)
    #expect(parsed.detail?.contains("502 Bad Gateway") == true)
    #expect(parsed.detail?.contains("self-signed certificate") == true)

    // 摘要入口（AgentCenter 实际走的那条）也得给出同一条错误
    let viaSummary = AgentPayloadSummary.summary(
        tool: .codex, hook: "Stop",
        payload: codexPayload(transcript: path), cwd: "/w/proj")
    #expect(viaSummary?.contains("502 Bad Gateway") == true)

    // 尾部不是 task_complete 时要继续往前找
    let t2 = try writeTranscript([realErrorLine, tokenCountLine])
    defer { try? FileManager.default.removeItem(
        atPath: (t2 as NSString).deletingLastPathComponent) }
    #expect(AgentPayloadSummary.codexFinalTurn(
        inTranscript: t2)?.error?.contains("502") == true)
}

private let tokenCountLine =
    #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_tokens":1}}}"#

@Test func codexStopDonePrefersHookMessage() throws {
    let path = try writeTranscript([realDoneLine])
    defer { try? FileManager.default.removeItem(
        atPath: (path as NSString).deletingLastPathComponent) }

    let withHook = AgentPayloadSummary.codexStop(
        codexPayload(transcript: path, message: "收工"))
    #expect(withHook.isFailure == false)
    #expect(withHook.detail == "收工")

    // 载荷字段缺失时用 transcript 的 last_agent_message 兜底
    let withoutHook = AgentPayloadSummary.codexStop(
        codexPayload(transcript: path))
    #expect(withoutHook.isFailure == false)
    #expect(withoutHook.detail == "改完了，测试都过了")
}

@Test func codexStopWithoutTranscriptIsNotHardJudgedFailure() {
    // 读不到 transcript 时，宁可说"完工"也不要冤枉成报错
    let parsed = AgentPayloadSummary.codexStop(codexPayload(transcript: nil))
    #expect(parsed.isFailure == false)
    #expect(parsed.detail == nil)
}

@Test func codexFailureAlertsAsErrorAndThrottles() {
    var store = AgentSessionStore()
    let base = Date(timeIntervalSince1970: 1_793_788_915)
    func stopEvent() -> AgentEvent {
        AgentEvent(
            tool: .codex, hook: "Stop", cwd: "/w/proj",
            payload: Data("{}".utf8), isFailure: true)
    }
    store.apply(
        AgentEvent(tool: .codex, hook: "UserPromptSubmit", cwd: "/w/proj"),
        at: base)
    let first = store.apply(stopEvent(), detail: "502 Bad Gateway",
                            at: base.addingTimeInterval(1))
    #expect(first?.kind == .error)
    // 会话已结束（state=.done），紧接着的第二次失败仍要能按 errorThrottle 节流
    let again = store.apply(stopEvent(), detail: "502 Bad Gateway",
                            at: base.addingTimeInterval(30))
    #expect(again == nil)
    let later = store.apply(stopEvent(), detail: "502 Bad Gateway",
                            at: base.addingTimeInterval(121))
    #expect(later?.kind == .error)
}

@Test func otherToolsStopStillAnnouncesDone() {
    var store = AgentSessionStore()
    let base = Date(timeIntervalSince1970: 1_793_788_915)
    store.apply(
        AgentEvent(tool: .qwen, hook: "UserPromptSubmit", cwd: "/w/proj"),
        at: base)
    // 别的工具没有 StopFailure 事件，isFailure 不适用 → 一律按完工
    let alert = store.apply(
        AgentEvent(tool: .qwen, hook: "Stop", cwd: "/w/proj"),
        detail: "好了", at: base.addingTimeInterval(1))
    #expect(alert?.kind == .done)
}

@Test func codexUsesItsOwnCopyAndOthersKeepGenericTemplates() {
    for kind in [AgentAlertKind.needsConfirm, .done, .error] {
        let codexText = AgentCenter.message(
            for: AgentAlert(kind: kind, tool: .codex, project: "proj"))
        #expect(codexText.hasPrefix("codex ") || codexText.contains("codex"),
                "codex \(kind) 文案里必须点着 codex")
        #expect(codexText.contains("proj"))
        #expect(!codexText.contains("{") && !codexText.contains("}"),
                "占位符没被替换干净")
        for tool in AgentTool.allCases where tool != .codex {
            let generic = AgentCenter.message(
                for: AgentAlert(kind: kind, tool: tool, project: "proj"))
            #expect(generic.contains(tool.rawValue),
                    "\(tool) 的 \(kind) 应仍走通用模板")
        }
    }
}

@Test func codexCopyHasThreeVariantsPerKind() {
    // 防手滑删条目：随机抽一条时池子太小会很单调
    for kind in [AgentAlertKind.needsConfirm, .done, .error] {
        var seen = Set<String>()
        for _ in 0..<200 {
            seen.insert(AgentCenter.message(
                for: AgentAlert(kind: kind, tool: .codex, project: "p")))
        }
        #expect(seen.count >= 2, "codex \(kind) 文案池太小")
    }
}
