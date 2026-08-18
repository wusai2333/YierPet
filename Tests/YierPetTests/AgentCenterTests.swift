import Foundation
import Testing
@testable import YierPet

private final class SpyDelegate: AgentCenterDelegate {
    var fired: [ReminderKind] = []
    func agentCenter(
        _ center: AgentCenter, fire kind: ReminderKind, message: String
    ) {
        fired.append(kind)
    }
}

/// 单工具开关关闭后，其 needsConfirm 旧会话的到期轻提醒须被门控过滤。
/// 不 start()（不起 server/timer），simulate 喂 qwen 事件，tick(at:) 注入时间。
@Test func toolToggleGatesDueNudges() {
    let center = AgentCenter()
    let spy = SpyDelegate()
    center.delegate = spy
    center.setEnabled(true)
    center.setEnabled(.qwen, true)
    defer {
        center.setEnabled(true)
        center.setEnabled(.qwen, true)
    }

    center.simulate(.agentNeedsConfirm)  // qwen PermissionRequest
    #expect(spy.fired == [.agentNeedsConfirm])

    // 121s 后轻提醒到期，但 qwen 开关已关 → 不提醒
    center.setEnabled(.qwen, false)
    center.tick(at: Date().addingTimeInterval(121))
    #expect(spy.fired.count == 1)

    // 开关恢复 → 下一轮到期重新提醒
    center.setEnabled(.qwen, true)
    center.tick(at: Date().addingTimeInterval(243))
    #expect(spy.fired == [.agentNeedsConfirm, .agentNeedsConfirm])
}

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
