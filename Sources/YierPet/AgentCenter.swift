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

    /// `now` 供测试注入；timer 走默认值。单工具开关门控到期重提醒。
    func tick(at now: Date = Date()) {
        guard isEnabled else { return }
        for alert in store.dueNudges(at: now) where isEnabled(alert.tool) {
            fire(alert)
        }
        store.pruneStale(at: now)
    }

    private func handle(_ event: AgentEvent) {
        guard isEnabled, isEnabled(event.tool) else { return }
        var event = event
        let detail: String?
        if event.tool == .codex, event.hook == "Stop", event.isFailure == nil,
           let payload = event.payload {
            // codex 没有失败专用事件，Stop 里混着 API 报错：一次解析拿到
            // 摘要 + 是否失败，失败标志交给状态机按报错提醒。
            let parsed = AgentPayloadSummary.codexStop(payload)
            detail = AgentPayloadSummary.clean(parsed.detail)
            event.isFailure = parsed.isFailure
        } else {
            detail = AgentPayloadSummary.summary(
                tool: event.tool, hook: event.hook, payload: event.payload,
                cwd: event.cwd)
        }
        if let alert = store.apply(event, detail: detail, at: Date()) {
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

    /// codex 专属文案。它的"等确认"是沙箱越界审批、"报错"是网关/限流把请求弹回来
    /// （都从 codex 0.166 实测的事件语义来），跟通用模板的话风区分开。
    /// 其余六个工具仍走 messages 里的通用模板，一字未改。
    private static let toolMessages: [AgentTool: [AgentAlertKind: [String]]] = [
        .codex: [
            .needsConfirm: [
                "codex 想越出沙箱动 {proj}，得你点头才行～",
                "{proj} 里的 codex 卡在了授权这一步，等你批！",
                "codex 在 {proj} 举着命令等你放行呐",
            ],
            .done: [
                "codex 交了 {proj} 这轮，回头验收一下～",
                "叮——codex 在 {proj} 说它搞定了！",
                "{proj} 这边 codex 收工啦，下一句给它？",
            ],
            .error: [
                "codex 在 {proj} 被网关弹回来了……去看看？",
                "呜，codex 在 {proj} 把这轮跑丢了（多半是接口）……",
                "codex 卡在 {proj} 的请求里出不来了，快去瞅一眼！",
            ],
        ],
    ]

    static func message(for alert: AgentAlert) -> String {
        let pool = toolMessages[alert.tool]?[alert.kind] ?? messages[alert.kind]
        let template = pool?.randomElement() ?? ""
        var text = template
            .replacingOccurrences(of: "{tool}", with: alert.tool.rawValue)
            .replacingOccurrences(of: "{proj}", with: alert.project)
        if let detail = alert.detail, !detail.isEmpty {
            text += "\n『\(detail)』"
        }
        return text
    }
}
