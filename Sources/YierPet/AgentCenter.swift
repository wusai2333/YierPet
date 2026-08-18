import AppKit

protocol AgentCenterDelegate: AnyObject {
    func agentCenter(
        _ center: AgentCenter, fire kind: ReminderKind, message: String)
}

/// Receives agent hook events (via AgentServer), tracks session states and
/// fires pet reminders. Ticks every 30s for re-nudges and stale cleanup.
final class AgentCenter {
    weak var delegate: AgentCenterDelegate?

    private var store = AgentSessionStore()
    private let server = AgentServer()
    private var timer: Timer?

    private static let masterKey = "agent.enabled"
    private static let soundKey = "agent.sound.enabled"
    private static func toolKey(_ tool: AgentTool) -> String {
        "agent.tool.\(tool.rawValue).enabled"
    }

    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.masterKey) == nil { return true }
        return defaults.bool(forKey: Self.masterKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.masterKey)
    }

    func isEnabled(_ tool: AgentTool) -> Bool {
        let defaults = UserDefaults.standard
        let key = Self.toolKey(tool)
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    func setEnabled(_ tool: AgentTool, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.toolKey(tool))
    }

    var soundEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.soundKey) == nil { return true }
        return defaults.bool(forKey: Self.soundKey)
    }

    func setSoundEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.soundKey)
    }

    var anyWorking: Bool { store.anyWorking }
    var snapshot: [AgentSessionStore.SessionInfo] { store.snapshot }

    func start() {
        server.onEvent = { [weak self] event in self?.handle(event) }
        server.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: 30, repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
    }

    private func tick() {
        guard isEnabled else { return }
        let now = Date()
        for alert in store.dueNudges(at: now) {
            fire(alert)
        }
        store.pruneStale(at: now)
    }

    private func handle(_ event: AgentEvent) {
        guard isEnabled, isEnabled(event.tool) else { return }
        if let alert = store.apply(event, at: Date()) {
            fire(alert)
        }
    }

    private func fire(_ alert: AgentAlert) {
        let kind: ReminderKind
        switch alert.kind {
        case .needsConfirm: kind = .agentNeedsConfirm
        case .done: kind = .agentDone
        case .error: kind = .agentError
        }
        delegate?.agentCenter(
            self, fire: kind, message: Self.message(for: alert))
    }

    /// Injects a fake event for the hidden test menu.
    func simulate(_ kind: ReminderKind) {
        let cwd = FileManager.default.currentDirectoryPath
        switch kind {
        case .agentNeedsConfirm:
            handle(AgentEvent(
                tool: .qwen, hook: "PermissionRequest", cwd: cwd))
        case .agentDone:
            handle(AgentEvent(
                tool: .qwen, hook: "UserPromptSubmit", cwd: cwd))
            handle(AgentEvent(tool: .qwen, hook: "Stop", cwd: cwd))
        case .agentError:
            handle(AgentEvent(
                tool: .qwen, hook: "PostToolUseFailure", cwd: cwd))
        default:
            break
        }
    }

    private static let messages: [AgentAlertKind: [String]] = [
        .needsConfirm: [
            "{tool} 在 {proj} 等你确认呢，快去瞅瞅！",
            "{tool} 卡在 {proj} 等你拍板啦～",
            "喂喂——{proj} 里的 {tool} 需要你确认一下！",
        ],
        .done: [
            "{tool} 把 {proj} 的活儿干完啦，等你下一句～",
            "{proj} 这边 {tool} 干完咯，验收验收？",
            "叮——{tool} 在 {proj} 完工啦！",
        ],
        .error: [
            "{tool} 在 {proj} 碰壁了……要不要去看看？",
            "呜，{proj} 的 {tool} 报错了……",
            "{tool} 在 {proj} 摔了一跤，快去扶一把！",
        ],
    ]

    static func message(for alert: AgentAlert) -> String {
        let template = messages[alert.kind]?.randomElement() ?? ""
        return template
            .replacingOccurrences(of: "{tool}", with: alert.tool.rawValue)
            .replacingOccurrences(of: "{proj}", with: alert.project)
    }
}
