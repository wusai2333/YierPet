import Foundation
import Testing
@testable import YierPet

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func event(
    _ hook: String, tool: AgentTool = .qwen, cwd: String = "/w/proj"
) -> AgentEvent {
    AgentEvent(tool: tool, hook: hook, cwd: cwd)
}

@Test func permissionRequestAlertsOnceUntilResolved() {
    var store = AgentSessionStore()
    #expect(store.apply(event("PermissionRequest"), at: t0) != nil)
    #expect(store.apply(event("PermissionRequest"), at: t0 + 5) == nil)
    // 用户回应后解除，再次请求要再提醒
    _ = store.apply(event("UserPromptSubmit"), at: t0 + 10)
    #expect(store.apply(event("PermissionRequest"), at: t0 + 15) != nil)
}

@Test func stopAfterWorkingAlertsDone() {
    var store = AgentSessionStore()
    _ = store.apply(event("UserPromptSubmit"), at: t0)
    let alert = store.apply(event("Stop"), at: t0 + 30)
    #expect(alert?.kind == .done)
    #expect(alert?.tool == .qwen)
    #expect(alert?.project == "proj")
    // 重复 Stop 不重复提醒
    #expect(store.apply(event("Stop"), at: t0 + 60) == nil)
}

@Test func errorThrottle60s() {
    var store = AgentSessionStore()
    _ = store.apply(event("UserPromptSubmit"), at: t0)
    #expect(store.apply(event("PostToolUseFailure"), at: t0 + 1) != nil)
    #expect(store.apply(event("PostToolUseFailure"), at: t0 + 30) == nil)
    #expect(store.apply(event("PostToolUseFailure"), at: t0 + 62) != nil)
}

@Test func nudgesEvery120sWhileWaiting() {
    var store = AgentSessionStore()
    _ = store.apply(event("PermissionRequest"), at: t0)
    #expect(store.dueNudges(at: t0 + 60).isEmpty)
    #expect(store.dueNudges(at: t0 + 121).count == 1)
    #expect(store.dueNudges(at: t0 + 130).isEmpty)
    #expect(store.dueNudges(at: t0 + 245).count == 1)
    // 解决后不再轻提醒
    _ = store.apply(event("UserPromptSubmit"), at: t0 + 300)
    #expect(store.dueNudges(at: t0 + 500).isEmpty)
}

@Test func sessionEndRemovesSession() {
    var store = AgentSessionStore()
    _ = store.apply(event("UserPromptSubmit"), at: t0)
    #expect(store.apply(event("SessionEnd"), at: t0 + 5) == nil)
    #expect(store.snapshot.isEmpty)
}

@Test func staleSessionsPruned() {
    var store = AgentSessionStore()
    _ = store.apply(event("UserPromptSubmit"), at: t0)
    store.pruneStale(at: t0 + 599)
    #expect(store.snapshot.count == 1)
    store.pruneStale(at: t0 + 601)
    #expect(store.snapshot.isEmpty)
}

@Test func sessionsKeyedByToolAndCwd() {
    var store = AgentSessionStore()
    _ = store.apply(event("UserPromptSubmit", tool: .qwen), at: t0)
    _ = store.apply(event("UserPromptSubmit", tool: .omp), at: t0)
    _ = store.apply(
        event("UserPromptSubmit", tool: .qwen, cwd: "/w/other"), at: t0)
    #expect(store.snapshot.count == 3)
    #expect(store.anyWorking)
}

@Test func subagentStopIsHeartbeatNotDone() {
    var store = AgentSessionStore()
    _ = store.apply(event("UserPromptSubmit"), at: t0)
    #expect(store.apply(event("SubagentStop"), at: t0 + 30) == nil)
    #expect(store.snapshot.first?.state == .working)
}

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
