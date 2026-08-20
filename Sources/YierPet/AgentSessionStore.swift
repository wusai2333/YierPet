import Foundation

/// Agent tools that YierPet can watch.
enum AgentTool: String, CaseIterable {
    case qwen, qodercli, opencode, omp, omo, dsh
}

/// What the pet should announce.
enum AgentAlertKind {
    case needsConfirm
    case done
    case error
}

struct AgentAlert {
    let kind: AgentAlertKind
    let tool: AgentTool
    let project: String
    var detail: String? = nil
}

/// One normalized hook event.
struct AgentEvent {
    let tool: AgentTool
    let hook: String
    let cwd: String
    var payload: Data? = nil
}

/// Pure agent session state machine: no timers, no I/O. Callers inject `now`.
struct AgentSessionStore {
    enum SessionState { case working, needsConfirm, done }

    struct Session {
        let tool: AgentTool
        let cwd: String
        var state: SessionState
        var lastEvent: Date
        var lastNudge: Date
        var lastErrorAlert: Date
        var lastDetail: String? = nil
    }

    struct SessionInfo {
        let tool: AgentTool
        let project: String
        let state: SessionState
        let lastEvent: Date
    }

    static let nudgeInterval: TimeInterval = 120
    static let errorThrottle: TimeInterval = 60
    static let staleAfter: TimeInterval = 600

    private(set) var sessions: [String: Session] = [:]

    static func key(tool: AgentTool, cwd: String) -> String {
        "\(tool.rawValue)\u{1}\(cwd)"
    }

    static func project(of cwd: String) -> String {
        (cwd as NSString).lastPathComponent
    }

    var anyWorking: Bool {
        sessions.values.contains { $0.state == .working }
    }

    var snapshot: [SessionInfo] {
        sessions.values
            .map {
                SessionInfo(
                    tool: $0.tool, project: Self.project(of: $0.cwd),
                    state: $0.state, lastEvent: $0.lastEvent)
            }
            .sorted { $0.lastEvent > $1.lastEvent }
    }

    /// Feeds one event. Returns an alert when this transition should notify.
    mutating func apply(
        _ event: AgentEvent, detail: String? = nil, at now: Date
    ) -> AgentAlert? {
        let key = Self.key(tool: event.tool, cwd: event.cwd)

        if event.hook == "SessionEnd" {
            sessions[key] = nil
            return nil
        }

        var session = sessions[key] ?? Session(
            tool: event.tool, cwd: event.cwd, state: .done,
            lastEvent: now, lastNudge: .distantPast,
            lastErrorAlert: .distantPast)
        let previous = session.state
        session.lastEvent = now
        if let detail, !detail.isEmpty { session.lastDetail = detail }
        var alert: AgentAlert?

        switch event.hook {
        case "PermissionRequest", "Notification":
            session.state = .needsConfirm
            if previous != .needsConfirm {
                session.lastNudge = now
                alert = AgentAlert(
                    kind: .needsConfirm, tool: event.tool,
                    project: Self.project(of: event.cwd), detail: detail)
            }
        case "Stop":
            session.state = .done
            if previous != .done {
                alert = AgentAlert(
                    kind: .done, tool: event.tool,
                    project: Self.project(of: event.cwd), detail: detail)
            }
        case "PostToolUseFailure", "StopFailure":
            // StopFailure（qwen/qodercli 的 API 错误终止）回合已结束；
            // PostToolUseFailure 只是工具出错，agent 还在干活。
            session.state = event.hook == "StopFailure" ? .done : .working
            if now.timeIntervalSince(session.lastErrorAlert)
                >= Self.errorThrottle {
                session.lastErrorAlert = now
                alert = AgentAlert(
                    kind: .error, tool: event.tool,
                    project: Self.project(of: event.cwd), detail: detail)
            }
        default:
            // Heartbeats: UserPromptSubmit/PreToolUse/PostToolUse/Subagent*
            session.state = .working
            if event.hook == "UserPromptSubmit" {
                // 新轮次：清掉上一轮摘要，防提取失败时气泡显示陈旧内容
                session.lastDetail = nil
            }
        }

        sessions[key] = session
        return alert
    }

    /// needsConfirm sessions due for a re-nudge.
    mutating func dueNudges(at now: Date) -> [AgentAlert] {
        var alerts: [AgentAlert] = []
        for (key, var session) in sessions
        where session.state == .needsConfirm
            && now.timeIntervalSince(session.lastNudge)
                >= Self.nudgeInterval {
            session.lastNudge = now
            sessions[key] = session
            alerts.append(
                AgentAlert(
                    kind: .needsConfirm, tool: session.tool,
                    project: Self.project(of: session.cwd),
                    detail: session.lastDetail))
        }
        return alerts
    }

    /// Drops sessions silent for staleAfter (agent exited or was killed).
    mutating func pruneStale(at now: Date) {
        sessions = sessions.filter {
            now.timeIntervalSince($0.value.lastEvent) < Self.staleAfter
        }
    }
}
