import Foundation

/// Agent tools that YierPet can watch.
enum AgentTool: String, CaseIterable {
    case qwen, qodercli, opencode, omp, omo, dsh, codex

    /// 该工具的 Stop 事件里混着报错（没有独立的失败事件）——
    /// Stop 载荷标为失败时要按报错提醒，而不是"干完啦"。
    var carriesErrorOnStop: Bool { self == .codex }
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
    /// 该事件本身代表"这一轮以失败收场"（目前只有 codex 的 Stop 会置位：
    /// codex 没有 StopFailure/Notification 事件，且 stop 载荷里没有 error 字段，
    /// 失败要从 transcript 的 task_complete.error.message 判定，见 AgentPayloadSummary）。
    var isFailure: Bool? = nil
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
        /// 本轮开工时间（UserPromptSubmit）。codex 报错的那一轮不会发 Stop
        /// （实测），所以用"开工后迟迟没收口"兜住失败/挂起。
        var lastTurnStart: Date? = nil
        var lastStallAlert: Date = .distantPast
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
    /// 看门狗：一轮开工后迟迟没收到收口事件，就按报错提醒一次。
    /// 阈值必须短于 staleAfter(600s)，否则会话先被当"久无动静"清掉、永远等不到提醒。
    static let stallAfter: TimeInterval = 300
    static let stallThrottle: TimeInterval = 300

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
            lastErrorAlert: .distantPast, lastStallAlert: .distantPast)
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
            session.lastTurnStart = nil   // 收口了，看门狗重新计时
            if event.tool.carriesErrorOnStop && event.isFailure == true {
                // codex 把 API 报错也塞在 Stop 里（限流/网关错误都会走到这里）：
                // 按报错提醒，并共用 errorThrottle，免得重试循环刷屏
                if now.timeIntervalSince(session.lastErrorAlert)
                    >= Self.errorThrottle {
                    session.lastErrorAlert = now
                    alert = AgentAlert(
                        kind: .error, tool: event.tool,
                        project: Self.project(of: event.cwd), detail: detail)
                }
            } else if previous != .done {
                alert = AgentAlert(
                    kind: .done, tool: event.tool,
                    project: Self.project(of: event.cwd), detail: detail)
            }
        case "PostToolUseFailure", "StopFailure":
            // StopFailure（qwen/qodercli 的 API 错误终止）回合已结束；
            // PostToolUseFailure 只是工具出错，agent 还在干活。
            session.state = event.hook == "StopFailure" ? .done : .working
            if event.hook == "StopFailure" { session.lastTurnStart = nil }
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
                // 记下开工时间，看门狗据此判断"迟迟没收口"
                session.lastTurnStart = now
            }
        }

        sessions[key] = session
        return alert
    }

    /// needsConfirm 到点的重提醒 + 看门狗：一轮开工后迟迟没收到收口事件。
    mutating func dueNudges(at now: Date) -> [AgentAlert] {
        var alerts: [AgentAlert] = []
        for (key, var session) in sessions {
            if session.state == .needsConfirm,
               now.timeIntervalSince(session.lastNudge) >= Self.nudgeInterval {
                session.lastNudge = now
                sessions[key] = session
                alerts.append(
                    AgentAlert(
                        kind: .needsConfirm, tool: session.tool,
                        project: Self.project(of: session.cwd),
                        detail: session.lastDetail))
                continue
            }
            // 看门狗只对"报错不发声"的工具开火（codex：失败的 turn 根本不发 Stop，
            // qwen/qodercli/opencode 等有自己的失败事件，不需要，免得长任务误报）。
            guard session.tool.carriesErrorOnStop,
                  session.state == .working,
                  let turnStart = session.lastTurnStart,
                  now.timeIntervalSince(turnStart) >= Self.stallAfter,
                  now.timeIntervalSince(session.lastStallAlert)
                    >= Self.stallThrottle
            else { continue }
            session.lastStallAlert = now
            sessions[key] = session
            let minutes = Int(now.timeIntervalSince(turnStart) / 60)
            alerts.append(
                AgentAlert(
                    kind: .error, tool: session.tool,
                    project: Self.project(of: session.cwd),
                    detail: "已经 \(minutes) 分钟没回话（本轮起于 "
                        + Self.clockFormatter.string(from: turnStart) + "）"))
        }
        return alerts
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Drops sessions silent for staleAfter (agent exited or was killed).
    mutating func pruneStale(at now: Date) {
        sessions = sessions.filter {
            now.timeIntervalSince($0.value.lastEvent) < Self.staleAfter
        }
    }
}
