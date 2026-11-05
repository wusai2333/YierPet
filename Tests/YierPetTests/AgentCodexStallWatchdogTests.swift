import Foundation
import Testing
@testable import YierPet

// 看门狗：codex 报错的那一轮不发 Stop（实测），只能用"开工后迟迟没收口"兜住。
// 阈值必须短于 staleAfter，否则会话先被 pruneStale 清掉，提醒永远发不出来。

private let base = Date(timeIntervalSince1970: 1_793_900_000)

private func started(_ tool: AgentTool) -> AgentEvent {
    AgentEvent(tool: tool, hook: "UserPromptSubmit", cwd: "/w/proj")
}

private func at(_ seconds: TimeInterval) -> Date {
    base.addingTimeInterval(seconds)
}

@Test func codexTurnStallsIntoErrorAlertOnceThenThrottles() {
    var store = AgentSessionStore()
    store.apply(started(.codex), at: base)
    #expect(store.sessions.values.first?.state == .working)

    // 到点前不开火
    #expect(store.dueNudges(at: at(AgentSessionStore.stallAfter - 1)).isEmpty)

    let due = store.dueNudges(at: at(AgentSessionStore.stallAfter))
    #expect(due.count == 1)
    #expect(due.first?.kind == .error)
    #expect(due.first?.project == "proj")
    #expect(due.first?.detail?.contains("没回话") == true)

    // 紧接着的 tick 不重复刷屏（stallThrottle 300s）
    #expect(store.dueNudges(at: at(AgentSessionStore.stallAfter + 30)).isEmpty)
    let again = store.dueNudges(
        at: at(AgentSessionStore.stallAfter + 301))
    #expect(again.count == 1)
}

@Test func codexStopClearsTheWatchdog() {
    var store = AgentSessionStore()
    store.apply(started(.codex), at: base)
    store.apply(
        AgentEvent(tool: .codex, hook: "Stop", cwd: "/w/proj"),
        detail: "收工", at: at(10))
    // 已完成的一轮不该再被看门狗追认成报错
    #expect(store.dueNudges(at: at(1000)).isEmpty)
}

@Test func watchdogDoesNotFireForToolsWithTheirOwnFailureEvents() {
    var store = AgentSessionStore()
    store.apply(started(.qwen), at: base)
    // qwen/qodercli/opencode… 有 StopFailure / PostToolUseFailure，
    // 长任务本来就可能几分钟不动静 —— 看门狗对它们闭嘴，免得误报
    #expect(store.dueNudges(at: at(400)).isEmpty)
    #expect(store.dueNudges(at: at(550)).isEmpty)
}

@Test func needsConfirmRenudgeStillWorksAlongsideWatchdog() {
    var store = AgentSessionStore()
    store.apply(
        AgentEvent(tool: .codex, hook: "PermissionRequest", cwd: "/w/proj"),
        at: base)
    let nudges = store.dueNudges(at: at(AgentSessionStore.nudgeInterval + 1))
    #expect(nudges.count == 1)
    #expect(nudges.first?.kind == .needsConfirm)
}

@Test func stallThresholdLeavesRoomBeforePrune() {
    // 看门狗必须在会话被当"久无动静"清掉之前开火
    #expect(AgentSessionStore.stallAfter < AgentSessionStore.staleAfter)
}

/// 隐藏菜单（Option+右键 →「测试提醒」）的 codex 变体：
/// 三种提醒都得发出来，且用的是 codex 专属文案。
@Test func simulateCoversCodexCopyForAllThreeKinds() {
    final class Spy: AgentCenterDelegate {
        var messages: [(kind: ReminderKind, text: String)] = []
        func agentCenter(
            _ center: AgentCenter, fire kind: ReminderKind, message: String
        ) { messages.append((kind, message)) }
    }
    let kinds = [ReminderKind.agentNeedsConfirm, .agentDone, .agentError]
    for kind in kinds {
        let center = AgentCenter()
        let spy = Spy()
        center.delegate = spy
        center.setEnabled(true)
        center.setEnabled(.codex, true)
        center.simulate(kind, tool: .codex)
        #expect(spy.messages.count == 1, "\(kind) 没发出提醒")
        let text = spy.messages.first?.text ?? ""
        #expect(text.contains("codex"), "\(kind) 没走 codex 文案：\(text)")
        switch kind {
        case .agentError:
            // 报错演练的是看门狗路径，摘要里应带"没回话"
            #expect(text.contains("没回话"), "codex 报错提醒应来自看门狗：\(text)")
        case .agentDone:
            #expect(text.contains("改完了，测试都过了"))
        default:
            break
        }
    }
}

/// 默认工具仍是 qwen：老菜单项行为不变（文案走通用模板）。
@Test func simulateDefaultsToQwenGenericCopy() {
    final class Spy: AgentCenterDelegate {
        var texts: [String] = []
        func agentCenter(
            _ center: AgentCenter, fire kind: ReminderKind, message: String
        ) { texts.append(message) }
    }
    let center = AgentCenter()
    let spy = Spy()
    center.delegate = spy
    center.setEnabled(true)
    center.setEnabled(.qwen, true)
    center.simulate(.agentDone)
    #expect(spy.texts.first?.contains("qwen") == true)
    #expect(!(spy.texts.first ?? "").contains("codex"))
}
