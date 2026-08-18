# Agent 哨兵 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** YierPet 内置 loopback HTTP 服务接收 5 个 agent CLI（qwen/qodercli/opencode/omp/dsh）钩子推送的状态事件，桌宠以气泡+动作+提示音提醒"等确认/报错/完成"，并镜像"工作中"状态。

**Architecture:** 各工具 hook 机制 → 统一 `~/.yierpet/hook.sh`（curl 转发，JS/TS 插件直接 fetch）→ YierPet `AgentServer`（NWListener 最小 HTTP）→ `AgentCenter`（纯状态机 `AgentSessionStore` + 30s tick）→ delegate 驱动现有气泡/动画/心情系统。

**Tech Stack:** Swift（AppKit + Network.framework，零第三方依赖）、XCTest（新增 test target）、shell/curl、TypeScript（opencode 插件 / omp 扩展）。

**Spec:** `docs/superpowers/specs/2026-08-18-agent-watch-design.md`（commit 66457ee）。

**对 spec 的三处实现层细化（不改变已确认的行为）：**
1. agent 文案语料池放在 `AgentCenter` 内（沿用 `ReminderCenter.messages` 的模式），而不是塞进 `ReminderCenter`——降低耦合；`ReminderKind` 仍新增 3 个 agent case 用于开关与测试菜单。
2. 静默清理（10 分钟）作用于**所有**状态的会话，不止 working——防止被杀的 agent 永远留在 needsConfirm 每 2 分钟轻提醒；行为比 spec 更安静，方向一致。
3. opencode 插件注册方式：向其 `opencode.json` 的 `plugin` 数组追加 `file://<path>` 条目（用户现有 loongsuite-pilot 插件即此模式，已验证）。

## Global Constraints

- 平台 macOS 13+，纯 AppKit + 系统框架，**禁止引入任何第三方 Swift 依赖**。
- 语言模式 Swift 5：正式构建走 `build.sh`（`swiftc -O Sources/YierPet/*.swift`，默认 Swift 5 模式）；`swift build`/`swift test` 需靠 Package.swift 的 `.swiftLanguageMode(.v5)` 对齐（现状 Swift 6 模式有 5 个存量 actor-isolation 错误，与本功能无关，不要顺手修）。
- 钩子脚本/插件**绝不阻塞 agent**：网络超时 ≤1s，任何错误静默吞掉。
- 配置合并必须**幂等**、自有条目带 `.yierpet/hook.sh` 或 `yierpet` 标记、写前备份（`*.yierpet-bak`，已有不覆盖）、绝不动他人条目（如 qodercli 的 yunke 钩子）。
- 全部逻辑主线程执行（NWListener 回调必须 hop 回主线程再碰 UI/状态机）。
- UI 文案用中文，风格对齐现有语料（活泼、带语气词）。
- 提交信息风格对齐仓库现状：`feat:`/`docs:` 前缀 + 中文描述。

---

### Task 1: Package.swift 可测化 + AgentSessionStore 纯状态机（TDD）

**Files:**
- Modify: `Package.swift`
- Create: `Sources/YierPet/AgentSessionStore.swift`
- Test: `Tests/YierPetTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces: `AgentTool`（enum: qwen/qodercli/opencode/omp/dsh）、`AgentAlertKind`（needsConfirm/done/error）、`AgentAlert { kind, tool, project }`、`AgentEvent { tool, hook, cwd }`、`AgentSessionStore`（`apply(_:at:) -> AgentAlert?`、`dueNudges(at:) -> [AgentAlert]`、`pruneStale(at:)`、`anyWorking: Bool`、`snapshot: [SessionInfo]`、`SessionInfo { tool, project, state, lastEvent }`、`SessionState { working, needsConfirm, done }`）

- [ ] **Step 1: 修改 Package.swift（加 v5 语言模式 + test target）**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YierPet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "YierPet",
            path: "Sources/YierPet",
            resources: [.copy("Resources/spritesheet.webp")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "YierPetTests",
            dependencies: ["YierPet"],
            path: "Tests/YierPetTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: 验证 swift build 由红转绿**

Run: `swift build 2>&1 | tail -3`
Expected: 编译成功（此前 Swift 6 模式有 5 个 actor-isolation 错误；若仍报错且错误仍在 SpeechBubble.swift 等存量文件，检查 swiftSettings 是否生效）。

- [ ] **Step 3: 写失败测试**

创建 `Tests/YierPetTests/AgentSessionStoreTests.swift`：

```swift
import XCTest
@testable import YierPet

final class AgentSessionStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ hook: String, tool: AgentTool = .qwen, cwd: String = "/w/proj"
    ) -> AgentEvent {
        AgentEvent(tool: tool, hook: hook, cwd: cwd)
    }

    func testPermissionRequestAlertsOnceUntilResolved() {
        var store = AgentSessionStore()
        XCTAssertNotNil(store.apply(event("PermissionRequest"), at: t0))
        XCTAssertNil(store.apply(event("PermissionRequest"), at: t0 + 5))
        // 用户回应后解除，再次请求要再提醒
        _ = store.apply(event("UserPromptSubmit"), at: t0 + 10)
        XCTAssertNotNil(store.apply(event("PermissionRequest"), at: t0 + 15))
    }

    func testStopAfterWorkingAlertsDone() {
        var store = AgentSessionStore()
        _ = store.apply(event("UserPromptSubmit"), at: t0)
        let alert = store.apply(event("Stop"), at: t0 + 30)
        XCTAssertEqual(alert?.kind, .done)
        XCTAssertEqual(alert?.tool, .qwen)
        XCTAssertEqual(alert?.project, "proj")
        // 重复 Stop 不重复提醒
        XCTAssertNil(store.apply(event("Stop"), at: t0 + 60))
    }

    func testErrorThrottle60s() {
        var store = AgentSessionStore()
        _ = store.apply(event("UserPromptSubmit"), at: t0)
        XCTAssertNotNil(store.apply(event("PostToolUseFailure"), at: t0 + 1))
        XCTAssertNil(store.apply(event("PostToolUseFailure"), at: t0 + 30))
        XCTAssertNotNil(store.apply(event("PostToolUseFailure"), at: t0 + 62))
    }

    func testNudgesEvery120sWhileWaiting() {
        var store = AgentSessionStore()
        _ = store.apply(event("PermissionRequest"), at: t0)
        XCTAssertTrue(store.dueNudges(at: t0 + 60).isEmpty)
        XCTAssertEqual(store.dueNudges(at: t0 + 121).count, 1)
        XCTAssertTrue(store.dueNudges(at: t0 + 130).isEmpty)
        XCTAssertEqual(store.dueNudges(at: t0 + 245).count, 1)
        // 解决后不再轻提醒
        _ = store.apply(event("UserPromptSubmit"), at: t0 + 300)
        XCTAssertTrue(store.dueNudges(at: t0 + 500).isEmpty)
    }

    func testSessionEndRemovesSession() {
        var store = AgentSessionStore()
        _ = store.apply(event("UserPromptSubmit"), at: t0)
        XCTAssertNil(store.apply(event("SessionEnd"), at: t0 + 5))
        XCTAssertTrue(store.snapshot.isEmpty)
    }

    func testStaleSessionsPruned() {
        var store = AgentSessionStore()
        _ = store.apply(event("UserPromptSubmit"), at: t0)
        store.pruneStale(at: t0 + 599)
        XCTAssertEqual(store.snapshot.count, 1)
        store.pruneStale(at: t0 + 601)
        XCTAssertTrue(store.snapshot.isEmpty)
    }

    func testSessionsKeyedByToolAndCwd() {
        var store = AgentSessionStore()
        _ = store.apply(event("UserPromptSubmit", tool: .qwen), at: t0)
        _ = store.apply(event("UserPromptSubmit", tool: .omp), at: t0)
        _ = store.apply(
            event("UserPromptSubmit", tool: .qwen, cwd: "/w/other"), at: t0)
        XCTAssertEqual(store.snapshot.count, 3)
        XCTAssertTrue(store.anyWorking)
    }

    func testSubagentStopIsHeartbeatNotDone() {
        var store = AgentSessionStore()
        _ = store.apply(event("UserPromptSubmit"), at: t0)
        XCTAssertNil(store.apply(event("SubagentStop"), at: t0 + 30))
        XCTAssertEqual(store.snapshot.first?.state, .working)
    }
}
```

- [ ] **Step 4: 运行测试确认失败**

Run: `swift test 2>&1 | tail -5`
Expected: 编译失败，`AgentSessionStore`/`AgentTool` 等未定义。

- [ ] **Step 5: 实现 AgentSessionStore**

创建 `Sources/YierPet/AgentSessionStore.swift`：

```swift
import Foundation

/// Agent tools that YierPet can watch.
enum AgentTool: String, CaseIterable {
    case qwen, qodercli, opencode, omp, dsh
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
}

/// One normalized hook event.
struct AgentEvent {
    let tool: AgentTool
    let hook: String
    let cwd: String
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
    mutating func apply(_ event: AgentEvent, at now: Date) -> AgentAlert? {
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
        var alert: AgentAlert?

        switch event.hook {
        case "PermissionRequest", "Notification":
            session.state = .needsConfirm
            if previous != .needsConfirm {
                session.lastNudge = now
                alert = AgentAlert(
                    kind: .needsConfirm, tool: event.tool,
                    project: Self.project(of: event.cwd))
            }
        case "Stop":
            session.state = .done
            if previous != .done {
                alert = AgentAlert(
                    kind: .done, tool: event.tool,
                    project: Self.project(of: event.cwd))
            }
        case "PostToolUseFailure":
            session.state = .working
            if now.timeIntervalSince(session.lastErrorAlert)
                >= Self.errorThrottle {
                session.lastErrorAlert = now
                alert = AgentAlert(
                    kind: .error, tool: event.tool,
                    project: Self.project(of: event.cwd))
            }
        default:
            // Heartbeats: UserPromptSubmit/PreToolUse/PostToolUse/Subagent*
            session.state = .working
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
                    project: Self.project(of: session.cwd)))
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
```

- [ ] **Step 6: 运行测试确认通过**

Run: `swift test 2>&1 | tail -5`
Expected: 全部 8 个测试 PASS。

- [ ] **Step 7: 确认正式构建不受影响**

Run: `./build.sh && ls build/YierPet.app/Contents/MacOS/YierPet`
Expected: 构建成功（glob 自动纳入新文件）。

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/YierPet/AgentSessionStore.swift Tests/YierPetTests/AgentSessionStoreTests.swift
git commit -m "feat: Agent 哨兵——会话状态机 AgentSessionStore（纯逻辑 + 单元测试）"
```

---

### Task 2: ReminderKind agent 分组 + AgentServer 本地 HTTP 服务（TDD）

**Files:**
- Modify: `Sources/YierPet/ReminderCenter.swift`（`ReminderKind` 枚举区）
- Create: `Sources/YierPet/AgentServer.swift`
- Test: `Tests/YierPetTests/AgentServerTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `AgentEvent`/`AgentTool`
- Produces: `ReminderKind.agentNeedsConfirm/agentDone/agentError` + `isAgent` + `agentCases`；`AgentServer`（`start()`、`stop()`、`onEvent: ((AgentEvent) -> Void)?`、`endpointString: String?`、`static endpointURL: URL`）

- [ ] **Step 1: ReminderKind 加 agent 分组**

在 `ReminderCenter.swift` 的 `ReminderKind` 枚举中：

case 列表末尾（`ideOvertime` 之后）追加：

```swift
    // Agent sentinel（Agent 哨兵）
    case agentNeedsConfirm
    case agentDone
    case agentError
```

`title` switch 追加：

```swift
        case .agentNeedsConfirm: return "等待确认"
        case .agentDone: return "任务完成"
        case .agentError: return "任务报错"
```

`isCompanion` 之后新增：

```swift
    /// Agent 哨兵提醒（由 AgentCenter 驱动，不走 tick）。
    var isAgent: Bool {
        switch self {
        case .agentNeedsConfirm, .agentDone, .agentError:
            return true
        default:
            return false
        }
    }
```

分组静态属性：`healthCases` 必须排除 agent（否则健康菜单和测试触发会混入），并新增 `agentCases`：

```swift
    static var healthCases: [ReminderKind] {
        allCases.filter { !$0.isSystem && !$0.isCompanion && !$0.isAgent }
    }
    static var systemCases: [ReminderKind] { allCases.filter { $0.isSystem } }
    static var companionCases: [ReminderKind] {
        allCases.filter { $0.isCompanion }
    }
    static var agentCases: [ReminderKind] { allCases.filter { $0.isAgent } }
```

- [ ] **Step 2: 写 AgentServer 失败测试**

创建 `Tests/YierPetTests/AgentServerTests.swift`：

```swift
import XCTest
@testable import YierPet

final class AgentServerTests: XCTestCase {
    func testReceivesPostedEvent() throws {
        let server = AgentServer()
        var received: AgentEvent?
        server.onEvent = { received = $0 }
        server.start()
        defer { server.stop() }

        // 等监听就绪（端口由系统分配）
        let readyDeadline = Date().addingTimeInterval(5)
        while server.endpointString == nil && Date() < readyDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let endpoint = server.endpointString,
              let url = URL(string: endpoint)
        else { return XCTFail("server never became ready") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("qwen", forHTTPHeaderField: "X-YierPet-Tool")
        request.setValue("PermissionRequest", forHTTPHeaderField: "X-YierPet-Hook")
        request.setValue("/w/proj", forHTTPHeaderField: "X-YierPet-Cwd")
        request.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: request).resume()

        let deadline = Date().addingTimeInterval(5)
        while received == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(received?.tool, .qwen)
        XCTAssertEqual(received?.hook, "PermissionRequest")
        XCTAssertEqual(received?.cwd, "/w/proj")
    }

    func testGarbageRequestDoesNotCrash() throws {
        let server = AgentServer()
        server.start()
        defer { server.stop() }
        let readyDeadline = Date().addingTimeInterval(5)
        while server.endpointString == nil && Date() < readyDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let endpoint = server.endpointString,
              let url = URL(string: endpoint) else {
            return XCTFail("server never became ready")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.httpBody = Data("not http at all".utf8)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in sem.signal() }
            .resume()
        _ = sem.wait(timeout: .now() + 5)
        // 活着走到这里即通过（服务未崩溃、连接被正常关闭）
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `swift test --filter AgentServerTests 2>&1 | tail -5`
Expected: 编译失败，`AgentServer` 未定义。

- [ ] **Step 4: 实现 AgentServer**

创建 `Sources/YierPet/AgentServer.swift`：

```swift
import Foundation
import Network

/// Minimal loopback HTTP server receiving agent hook events.
/// One request per connection: parse, deliver, respond, close.
final class AgentServer {
    var onEvent: ((AgentEvent) -> Void)?

    private var listener: NWListener?
    private(set) var port: UInt16?

    static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".yierpet")
    static let endpointURL = dir.appendingPathComponent("endpoint")

    var endpointString: String? {
        port.map { "http://127.0.0.1:\($0)/event" }
    }

    func start() {
        let params = NWParameters.tcp
        // 仅本机回环可达；lo0 不存在时退回默认（仍是本地监听）
        if let loopback = NWInterface(name: "lo0") {
            params.requiredLocalInterface = loopback
        }
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.port = listener.port?.rawValue
                self.writeEndpointFile()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(connection: connection, buffer: Data())
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        try? FileManager.default.removeItem(at: Self.endpointURL)
    }

    private func writeEndpointFile() {
        guard let endpoint = endpointString else { return }
        try? FileManager.default.createDirectory(
            at: Self.dir, withIntermediateDirectories: true)
        try? endpoint.data(using: .utf8)?.write(to: Self.endpointURL)
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumIncompleteLength: 16384
        ) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let event = Self.parse(accumulated) {
                self.onEvent?(event)
                self.respond(connection: connection, status: "200 OK")
                return
            }
            if error != nil || isComplete || accumulated.count > 65536 {
                self.respond(connection: connection, status: "400 Bad Request")
                return
            }
            self.receive(connection: connection, buffer: accumulated)
        }
    }

    /// Parses one complete HTTP request (headers + body) into an event.
    private static func parse(_ data: Data) -> AgentEvent? {
        guard let text = String(data: data, encoding: .utf8),
              let split = text.range(of: "\r\n\r\n")
        else { return nil }
        let head = String(text[..<split.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = split.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard text[bodyStart...].utf8.count >= contentLength else {
            return nil  // body 未收全，继续等
        }
        guard let tool = AgentTool(rawValue: headers["x-yierpet-tool"] ?? ""),
              let hook = headers["x-yierpet-hook"]
        else { return nil }
        return AgentEvent(
            tool: tool, hook: hook, cwd: headers["x-yierpet-cwd"] ?? "")
    }

    private func respond(connection: NWConnection, status: String) {
        let response =
            "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test 2>&1 | tail -5`
Expected: 全部测试 PASS（AgentSessionStore 8 个 + AgentServer 2 个）。

- [ ] **Step 6: Commit**

```bash
git add Sources/YierPet/ReminderCenter.swift Sources/YierPet/AgentServer.swift Tests/YierPetTests/AgentServerTests.swift
git commit -m "feat: Agent 哨兵——ReminderKind agent 分组与 loopback HTTP 服务 AgentServer"
```

---

### Task 3: AgentCenter + PetController 联动（气泡/动作/提示音/测试菜单）

**Files:**
- Create: `Sources/YierPet/AgentCenter.swift`
- Modify: `Sources/YierPet/PetController.swift`（属性区、`contextTags`、`buildMenu()`、`menuTestReminder`、文件末尾 delegate extension）

**Interfaces:**
- Consumes: Task 1 `AgentSessionStore`/`AgentEvent`/`AgentAlert`/`AgentTool`；Task 2 `AgentServer`、`ReminderKind.agent*`
- Produces: `AgentCenter`（`start()`、`delegate`、`isEnabled`/`setEnabled(_:)`、`isEnabled(_: AgentTool)`/`setEnabled(_: AgentTool, _: Bool)`、`soundEnabled`/`setSoundEnabled(_:)`、`anyWorking`、`snapshot`、`simulate(_ kind: ReminderKind)`）；`AgentCenterDelegate.agentCenter(_:fire:message:)`

- [ ] **Step 1: 实现 AgentCenter**

创建 `Sources/YierPet/AgentCenter.swift`：

```swift
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
```

- [ ] **Step 2: PetController 接入**

在 `PetController.swift` 中做以下修改：

属性区（`private let reminderCenter = ReminderCenter()` 旁）：

```swift
    private let agentCenter = AgentCenter()
```

`init?(sheet:)` 中（`reminderCenter.start()` 之后）：

```swift
        agentCenter.delegate = self
        agentCenter.start()
```

`contextTags` 的 `.normal` 分支改为（有 working 会话时待机偏向 work 表情）：

```swift
        case .normal:
            var tags = reminderCenter.frontEmotionTags
            if tags.isEmpty { tags = ["idle", "lazy", "happy"] }
            if agentCenter.anyWorking { tags.insert("work", at: 0) }
            return tags
```

`menuTestReminder` 路由 agent 类提醒：

```swift
    @objc private func menuTestReminder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ReminderKind(rawValue: raw) else { return }
        if kind.isAgent {
            agentCenter.simulate(kind)
        } else {
            reminderCenter.fire(kind)
        }
    }
```

- [ ] **Step 3: PetController 加 Agent 哨兵菜单与 delegate 实现**

`buildMenu()` 中，陪伴模式子菜单之后、隐藏测试菜单之前插入：

```swift
        // Agent sentinel toggles
        let agentMenu = NSMenu()
        let agentMasterItem = NSMenuItem(
            title: agentCenter.isEnabled ? "停用 Agent 哨兵" : "启用 Agent 哨兵",
            action: #selector(menuToggleAgentMaster),
            keyEquivalent: ""
        )
        agentMasterItem.target = self
        agentMenu.addItem(agentMasterItem)
        for tool in AgentTool.allCases {
            let item = NSMenuItem(
                title: "监听 \(tool.rawValue)",
                action: #selector(menuToggleAgentTool(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tool.rawValue
            item.state = agentCenter.isEnabled(tool) ? .on : .off
            agentMenu.addItem(item)
        }
        let agentSoundItem = NSMenuItem(
            title: "提示音",
            action: #selector(menuToggleAgentSound),
            keyEquivalent: ""
        )
        agentSoundItem.target = self
        agentSoundItem.state = agentCenter.soundEnabled ? .on : .off
        agentMenu.addItem(agentSoundItem)
        let agentItem = NSMenuItem(
            title: "Agent 哨兵", action: nil, keyEquivalent: "")
        menu.addItem(agentItem)
        menu.setSubmenu(agentMenu, for: agentItem)
```

菜单动作（与 `menuToggleReminder` 相邻处）：

```swift
    @objc private func menuToggleAgentMaster() {
        agentCenter.setEnabled(!agentCenter.isEnabled)
    }

    @objc private func menuToggleAgentTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tool = AgentTool(rawValue: raw) else { return }
        agentCenter.setEnabled(tool, !agentCenter.isEnabled(tool))
    }

    @objc private func menuToggleAgentSound() {
        agentCenter.setSoundEnabled(!agentCenter.soundEnabled)
    }
```

文件末尾新增 delegate extension（与现有 `ReminderCenterDelegate` extension 并列）：

```swift
// MARK: - AgentCenterDelegate

extension PetController: AgentCenterDelegate {
    func agentCenter(
        _ center: AgentCenter, fire kind: ReminderKind, message: String
    ) {
        guard !isThrowing else { return }
        stopWalk()
        say(message, duration: 6)

        if center.soundEnabled {
            let soundName: NSSound.Name?
            switch kind {
            case .agentNeedsConfirm: soundName = "Glass"
            case .agentError: soundName = "Basso"
            default: soundName = nil
            }
            if let soundName { NSSound(named: soundName)?.play() }
        }

        if style.isSticker {
            switch kind {
            case .agentNeedsConfirm:
                playStickerTags(["hot", "tired"], loops: 3)
            case .agentDone:
                playStickerTags(["happy", "love"], loops: 2)
            case .agentError:
                playStickerTags(["sad", "tired"], loops: 2)
            default:
                break
            }
            return
        }

        switch kind {
        case .agentNeedsConfirm:
            playOnce(.waiting, loops: 3)
        case .agentDone:
            playOnce(.waving, loops: 2)
        case .agentError:
            playOnce(.failed, loops: 2)
        default:
            break
        }
    }
}
```

- [ ] **Step 4: 构建 + 单元测试**

Run: `swift test 2>&1 | tail -3 && ./build.sh`
Expected: 测试全 PASS；build.sh 成功。

- [ ] **Step 5: 手工验证测试菜单链路**

Run: `open build/YierPet.app`

操作：右键宠物 → 按住 Option 再右键 → "测试提醒" → 分别点"触发等待确认"、"触发任务完成"、"触发任务报错"。
Expected: 每次气泡出现对应文案（含工具名与项目名）、宠物播放对应动作、等待确认/报错有提示音。验证后从"Agent 哨兵"子菜单确认各开关可切换（勾选态正确回显）。退出 app。

- [ ] **Step 6: Commit**

```bash
git add Sources/YierPet/AgentCenter.swift Sources/YierPet/PetController.swift
git commit -m "feat: Agent 哨兵——AgentCenter 接入桌宠（气泡/动作/提示音/开关菜单/测试注入）"
```

---

### Task 4: AgentHookInstaller（hook.sh + qwen/qodercli 钩子）+ 安装/卸载菜单 + 首个真实 E2E

**Files:**
- Create: `Sources/YierPet/AgentHookInstaller.swift`
- Modify: `Sources/YierPet/PetController.swift`（buildMenu 加安装/卸载项 + 两个 action）

**Interfaces:**
- Consumes: Task 1 `AgentTool`；Task 2 `AgentServer.dir`/`endpointURL`
- Produces: `AgentHookInstaller.installAll() -> String`、`uninstallAll() -> String`（后续任务往里加 opencode/omp/dsh 分支）

- [ ] **Step 1: 实现 AgentHookInstaller（qwen/qodercli 部分）**

创建 `Sources/YierPet/AgentHookInstaller.swift`：

```swift
import Foundation

/// Installs/uninstalls agent hooks. Idempotent: own entries are recognized
/// by the ".yierpet/hook.sh" marker; everything else is left untouched.
enum AgentHookInstaller {
    static let marker = ".yierpet/hook.sh"
    static let scriptURL = AgentServer.dir.appendingPathComponent("hook.sh")

    /// Claude-Code-style hook events registered for settings.json tools.
    static let hookEvents = [
        "PermissionRequest", "Notification", "Stop",
        "UserPromptSubmit", "PostToolUseFailure", "SessionEnd",
    ]

    private static let script = """
    #!/bin/sh
    # YierPet agent hook forwarder — forwards hook stdin JSON to YierPet.
    # Never blocks the agent: 1s timeout, silent on any error.
    endpoint=$(cat "$HOME/.yierpet/endpoint" 2>/dev/null)
    [ -n "$endpoint" ] || exit 0
    curl -m 1 -s -o /dev/null -X POST "$endpoint" \\
      -H "Content-Type: application/json" \\
      -H "X-YierPet-Tool: $1" \\
      -H "X-YierPet-Hook: $2" \\
      -H "X-YierPet-Cwd: $PWD" \\
      --data-binary @- 2>/dev/null
    exit 0

    """

    static func writeScript() {
        try? FileManager.default.createDirectory(
            at: AgentServer.dir, withIntermediateDirectories: true)
        try? script.data(using: .utf8)?.write(to: scriptURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - settings.json tools (qwen / qodercli)

    static func installSettingsHooks(
        settingsPath: String, tool: AgentTool
    ) throws {
        let url = URL(fileURLWithPath: settingsPath)
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else { throw NSError(domain: "yierpet", code: 1) }
        backup(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for eventName in hookEvents {
            var entries = hooks[eventName] as? [[String: Any]] ?? []
            entries.removeAll(where: isOwnEntry)
            entries.append(ownEntry(tool: tool, event: eventName))
            hooks[eventName] = entries
        }
        root["hooks"] = hooks
        try write(root, to: url)
    }

    static func uninstallSettingsHooks(settingsPath: String) throws {
        let url = URL(fileURLWithPath: settingsPath)
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else { return }
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false
        for (eventName, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll(where: isOwnEntry)
            if entries.count != before { changed = true }
            if entries.isEmpty {
                hooks[eventName] = nil
            } else {
                hooks[eventName] = entries
            }
        }
        guard changed else { return }
        root["hooks"] = hooks
        try write(root, to: url)
    }

    private static func isOwnEntry(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func ownEntry(
        tool: AgentTool, event: String
    ) -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": "\(scriptURL.path) \(tool.rawValue) \(event)",
                "timeout": 10,
            ]],
        ]
    }

    private static func write(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
    }

    private static func backup(_ url: URL) {
        let backupURL = url.appendingPathExtension("yierpet-bak")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }
    }

    // MARK: - Orchestration

    static func installAll() -> String {
        writeScript()
        let home = NSHomeDirectory()
        let targets: [(AgentTool, String)] = [
            (.qwen, "\(home)/.qwen/settings.json"),
            (.qodercli, "\(home)/.qoder/settings.json"),
        ]
        var ok: [String] = []
        var failed: [String] = []
        for (tool, path) in targets {
            do {
                try installSettingsHooks(settingsPath: path, tool: tool)
                ok.append(tool.rawValue)
            } catch {
                failed.append(tool.rawValue)
            }
        }
        var summary = "钩子已安装：\(ok.joined(separator: "、"))"
        if !failed.isEmpty {
            summary += "；失败：\(failed.joined(separator: "、"))"
        }
        return summary
    }

    static func uninstallAll() -> String {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.qwen/settings.json",
            "\(home)/.qoder/settings.json",
        ]
        for path in paths {
            try? uninstallSettingsHooks(settingsPath: path)
        }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: AgentServer.endpointURL)
        return "Agent 钩子已卸载"
    }
}
```

- [ ] **Step 2: PetController 菜单加安装/卸载项**

`buildMenu()` 的 Agent 哨兵子菜单中（提示音项之后）追加：

```swift
        agentMenu.addItem(.separator())
        let installItem = NSMenuItem(
            title: "安装 Agent 钩子",
            action: #selector(menuInstallAgentHooks),
            keyEquivalent: ""
        )
        installItem.target = self
        agentMenu.addItem(installItem)
        let uninstallItem = NSMenuItem(
            title: "卸载 Agent 钩子",
            action: #selector(menuUninstallAgentHooks),
            keyEquivalent: ""
        )
        uninstallItem.target = self
        agentMenu.addItem(uninstallItem)
```

动作：

```swift
    @objc private func menuInstallAgentHooks() {
        say(AgentHookInstaller.installAll(), duration: 8)
    }

    @objc private func menuUninstallAgentHooks() {
        say(AgentHookInstaller.uninstallAll(), duration: 8)
    }
```

- [ ] **Step 3: 构建 + 单元测试**

Run: `swift test 2>&1 | tail -3 && ./build.sh`
Expected: 测试全 PASS；build.sh 成功。

- [ ] **Step 4: 安装钩子并验证配置文件 diff 干净**

Run: `open build/YierPet.app`，右键 → Agent 哨兵 → "安装 Agent 钩子"，气泡提示后退出 app。

验证（全部要符合预期）：

```bash
# 备份已生成
ls ~/.qwen/settings.json.yierpet-bak ~/.qoder/settings.json.yierpet-bak
# 每个工具 6 个事件、命令指向 hook.sh
python3 -c "
import json
for p in ['$HOME/.qwen/settings.json', '$HOME/.qoder/settings.json']:
    d = json.load(open(p))
    mine = [e for ev in d['hooks'].values() for e in ev
            for h in e.get('hooks', []) if '.yierpet/hook.sh' in h.get('command', '')]
    print(p, len(mine))
"
# Expected: 两个文件各 6
# yunke 钩子仍在（qodercli）
grep -c yunke ~/.qoder/settings.json   # Expected: >= 1
# hook.sh 可执行
ls -l ~/.yierpet/hook.sh ~/.yierpet/endpoint
```

- [ ] **Step 5: 真实 E2E——curl 直推与 qwen 实跑**

```bash
# 先启动 YierPet（open build/YierPet.app），然后：
cd /tmp && printf '{}' | ~/.yierpet/hook.sh qwen PermissionRequest
```

Expected: 宠物立刻出现"等确认"气泡 + 动作 + 提示音。

再实跑 qwen：`cd /tmp && mkdir -p yierpet-e2e && cd yierpet-e2e && qwen`，输入一个会触发权限确认的请求（如"运行 shell 命令 ls -la"）。
Expected: 权限弹窗出现的同时宠物提醒；终端里回应后，agent 完成一轮时宠物出现"完成"气泡。

- [ ] **Step 6: 卸载验证**

菜单"卸载 Agent 钩子"后：

```bash
grep -c yierpet ~/.qwen/settings.json ~/.qoder/settings.json  # Expected: 均为 0
grep -c yunke ~/.qoder/settings.json                          # Expected: >= 1（他人条目未动）
ls ~/.yierpet/hook.sh 2>/dev/null                             # Expected: 不存在
```

重新"安装 Agent 钩子"（保持安装状态进入后续任务）。

- [ ] **Step 7: Commit**

```bash
git add Sources/YierPet/AgentHookInstaller.swift Sources/YierPet/PetController.swift
git commit -m "feat: Agent 哨兵——钩子安装器（hook.sh + qwen/qodercli 配置合并，幂等可卸载）"
```

---

### Task 5: opencode 插件 + omp 扩展

**Files:**
- Modify: `Sources/YierPet/AgentHookInstaller.swift`（新增 opencode/omp 安装卸载 + 两段 TS 源码常量 + installAll/uninstallAll 分支）

**Interfaces:**
- Consumes: Task 4 的 `AgentHookInstaller` 骨架（backup/write/marker 约定）
- Produces: `~/.config/opencode/plugins/yierpet.ts` + opencode.json `plugin` 数组的 `file://` 条目；`~/.omp/agent/extensions/yierpet-status.ts`

背景（已验证）：opencode 插件 API 为 `async (ctx) => Hooks`，`Hooks.event` 收 SDK 事件（`session.idle`/`session.error`/`message.updated` 等），`Hooks["permission.ask"]` 在权限请求时触发；本地插件以 `file://<绝对路径>` 注册进 `opencode.json` 的 `plugin` 数组（用户现有 loongsuite-pilot 条目即此模式）。omp/pi 扩展 API 为 `export default function (pi) { pi.on('agent_start' | 'tool_execution_start' | 'tool_execution_end' | 'message_end' | 'agent_settled' | 'agent_end', handler) }`，扩展目录自动发现（参考用户现有 orca-agent-status.ts）。

- [ ] **Step 1: 在 AgentHookInstaller 中加两段 TS 源码常量**

```swift
    static let opencodePluginURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/opencode/plugins/yierpet.ts")
    static let ompExtensionURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".omp/agent/extensions/yierpet-status.ts")

    private static let opencodePluginSource = #"""
    // YierPet agent sentinel — forwards opencode status to YierPet.
    // Endpoint file is written by YierPet on start; silent no-op if absent.
    import { readFileSync } from "node:fs";
    import { homedir } from "node:os";

    function endpoint(): string | null {
      try {
        const url = readFileSync(
          `${homedir()}/.yierpet/endpoint`, "utf8").trim();
        return url || null;
      } catch {
        return null;
      }
    }

    function post(hook: string, cwd: string): void {
      const url = endpoint();
      if (!url) return;
      fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-YierPet-Tool": "opencode",
          "X-YierPet-Hook": hook,
          "X-YierPet-Cwd": cwd,
        },
        body: "{}",
        signal: AbortSignal.timeout(1000),
      }).catch(() => {});
    }

    export const YierPetPlugin = async (ctx: { directory?: string }) => {
      const directory = ctx?.directory || process.cwd();
      return {
        event: async ({ event }: { event: { type: string } }) => {
          switch (event?.type) {
            case "session.idle":
              post("Stop", directory);
              break;
            case "session.error":
              post("PostToolUseFailure", directory);
              break;
            case "message.updated":
              post("PostToolUse", directory);
              break;
          }
        },
        "permission.ask": async () => {
          post("PermissionRequest", directory);
        },
      };
    };
    """#

    private static let ompExtensionSource = #"""
    // YierPet agent sentinel — forwards omp/pi status to YierPet.
    // Same pattern as orca-agent-status.ts: endpoint file + fire-and-forget.
    const HOOK_POST_TIMEOUT_MS = 1000

    function readEndpoint(): string | null {
      try {
        const fs = require('fs')
        const url = String(
          fs.readFileSync(`${process.env.HOME}/.yierpet/endpoint`, 'utf8')
        ).trim()
        return url || null
      } catch {
        return null
      }
    }

    function post(hookEventName: string): void {
      const url = readEndpoint()
      if (!url) return
      const controller =
        typeof AbortController !== 'undefined' ? new AbortController() : null
      const timeout = setTimeout(
        () => controller?.abort(), HOOK_POST_TIMEOUT_MS)
      if (typeof timeout.unref === 'function') timeout.unref()
      fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-YierPet-Tool': 'omp',
          'X-YierPet-Hook': hookEventName,
          'X-YierPet-Cwd': process.cwd(),
        },
        body: '{}',
        ...(controller ? { signal: controller.signal } : {}),
      }).catch(() => {}).finally(() => clearTimeout(timeout))
    }

    export default function (pi): void {
      pi.on('agent_start', () => post('UserPromptSubmit'))
      pi.on('tool_execution_start', () => post('PostToolUse'))
      pi.on('tool_execution_end', () => post('PostToolUse'))
      pi.on('message_end', (event) => {
        if (event?.message?.role === 'assistant') post('PostToolUse')
      })
      pi.on('agent_settled', () => post('Stop'))
      pi.on('agent_end', () => post('Stop'))
    }
    """#
```

- [ ] **Step 2: 加 opencode/omp 的安装与卸载方法**

```swift
    static func installOpencodePlugin() throws {
        let pluginDir = opencodePluginURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: pluginDir, withIntermediateDirectories: true)
        try opencodePluginSource.data(using: .utf8)?
            .write(to: opencodePluginURL)
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/opencode.json")
        guard let data = try? Data(contentsOf: configURL),
              var root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else { throw NSError(domain: "yierpet", code: 2) }
        backup(configURL)
        var plugins = root["plugin"] as? [String] ?? []
        plugins.removeAll { $0.contains("yierpet") }
        plugins.append("file://\(opencodePluginURL.path)")
        root["plugin"] = plugins
        try write(root, to: configURL)
    }

    static func uninstallOpencodePlugin() {
        try? FileManager.default.removeItem(at: opencodePluginURL)
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/opencode.json")
        guard let data = try? Data(contentsOf: configURL),
              var root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any],
              var plugins = root["plugin"] as? [String]
        else { return }
        let before = plugins.count
        plugins.removeAll { $0.contains("yierpet") }
        guard plugins.count != before else { return }
        root["plugin"] = plugins
        try? write(root, to: configURL)
    }

    static func installOmpExtension() throws {
        let extensionDir = ompExtensionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: extensionDir, withIntermediateDirectories: true)
        try ompExtensionSource.data(using: .utf8)?
            .write(to: ompExtensionURL)
    }

    static func uninstallOmpExtension() {
        try? FileManager.default.removeItem(at: ompExtensionURL)
    }
```

- [ ] **Step 3: 把 opencode/omp 接入 installAll/uninstallAll**

`installAll()` 的 targets 数组与循环之后、summary 之前：

```swift
        do {
            try installOpencodePlugin()
            ok.append("opencode")
        } catch {
            failed.append("opencode")
        }
        do {
            try installOmpExtension()
            ok.append("omp")
        } catch {
            failed.append("omp")
        }
```

`uninstallAll()` 的 paths 循环之后：

```swift
        uninstallOpencodePlugin()
        uninstallOmpExtension()
```

- [ ] **Step 4: 构建 + 安装 + 验证**

Run: `swift test 2>&1 | tail -3 && ./build.sh && open build/YierPet.app`

菜单"安装 Agent 钩子"，然后：

```bash
test -f ~/.config/opencode/plugins/yierpet.ts && echo plugin-ok
python3 -c "
import json
d = json.load(open('$HOME/.config/opencode/opencode.json'))
print([p for p in d.get('plugin', []) if 'yierpet' in p])
"
# Expected: ['file:///Users/wusai/.config/opencode/plugins/yierpet.ts']
test -f ~/.omp/agent/extensions/yierpet-status.ts && echo omp-ok
```

- [ ] **Step 5: 真实 E2E**

opencode：在任一项目跑 `opencode`，发一个会触发权限确认的指令（如写文件/跑命令，视其权限模式而定）。
Expected: 权限提示出现时宠物"等确认"提醒；agent 空闲时宠物"完成"提醒。

omp：在任一项目跑 `omp "随便改点什么或提问"`。
Expected: 运行中无提醒（心跳），agent_end 后宠物"完成"提醒。（yolo 模式下不会出现等确认，属预期。）

- [ ] **Step 6: Commit**

```bash
git add Sources/YierPet/AgentHookInstaller.swift
git commit -m "feat: Agent 哨兵——opencode 插件与 omp 扩展接入"
```

---

### Task 6: dsh 接入（扩展点调研 + 安装 + 关闭内置宠物）

**Files:**
- Modify: `Sources/YierPet/AgentHookInstaller.swift`

**Interfaces:**
- Consumes: Task 4/5 的安装器骨架
- Produces: dsh 扩展安装/卸载 + `~/.dsh/settings.yaml` 的 `pet.visible: false`

背景：dsh（deepseek-harness）源码在 `~/Work/tools/deepseek-harness`，基于 pi 框架；orca-agent-status.ts 注释明确 "Pi and OMP expose the same extension API"，预期 dsh 扩展机制与 omp 相同，但扩展目录位置需现场确认。

- [ ] **Step 1: 调研 dsh 的扩展加载位置**

```bash
grep -rn --include='*.ts' -E 'extension' ~/Work/tools/deepseek-harness/packages/*/src 2>/dev/null | grep -iE 'load|dir|discover|path' | head -15
ls ~/.dsh
```

判定标准：
- 找到类似 `~/.dsh/extensions`（或 settings.yaml 中 extensions 配置项）的自动发现目录 → 走 Step 2 方案 A；
- 只找到 settings.yaml 里的 hook/command 类配置 → 方案 B：按 qwen 模式注册 `hook.sh dsh <event>`；
- 两者都没有 → 方案 C：本任务只做关闭内置宠物，dsh 事件接入留空并在总结中明确告知用户（不要硬造机制）。

- [ ] **Step 2: 按调研结果实现（方案 A 示例）**

```swift
    static let dshExtensionURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("<调研确认的相对路径>/yierpet-status.ts")

    private static let dshExtensionSource = #"""
    // YierPet agent sentinel — forwards dsh status to YierPet.
    // （内容与 ompExtensionSource 相同，仅 X-YierPet-Tool 改为 "dsh"）
    """#
    // 实现时直接复制 ompExtensionSource，把 'omp' 替换为 'dsh'

    static func installDshExtension() throws {
        let dir = dshExtensionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try dshExtensionSource.data(using: .utf8)?
            .write(to: dshExtensionURL)
    }

    static func uninstallDshExtension() {
        try? FileManager.default.removeItem(at: dshExtensionURL)
    }

    /// YierPet 取代 dsh 内置宠物（鲸鱼娘）：pet.visible → false。
    static func disableDshBuiltinPet() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/settings.yaml")
        guard let text = try? String(contentsOf: url) else { return }
        let patched = text.replacingOccurrences(
            of: "pet:\n  visible: true",
            with: "pet:\n  visible: false")
        guard patched != text else { return }
        backup(url)
        try? patched.data(using: .utf8)?.write(to: url)
    }
```

installAll 追加（方案 A/B 时）：

```swift
        do {
            try installDshExtension()
            ok.append("dsh")
        } catch {
            failed.append("dsh")
        }
        disableDshBuiltinPet()
```

uninstallAll 追加 `uninstallDshExtension()`（不恢复 pet.visible，避免鲸鱼娘突然复活——spec 已确认）。

- [ ] **Step 3: 构建 + 安装 + E2E**

Run: `swift test 2>&1 | tail -3 && ./build.sh && open build/YierPet.app`

菜单"安装 Agent 钩子"后：

```bash
grep -A2 '^pet:' ~/.dsh/settings.yaml   # Expected: visible: false
```

跑一次 dsh（`cd ~/Work/tools/deepseek-harness && dsh`，发一条消息）。
Expected: 内置鲸鱼娘不再出现；agent 完成一轮时 YierPet"完成"提醒（方案 A/B 时）。

- [ ] **Step 4: Commit**

```bash
git add Sources/YierPet/AgentHookInstaller.swift
git commit -m "feat: Agent 哨兵——dsh 接入并关闭其内置宠物"
```

---

### Task 7: 会话状态展示 + README + 最终 E2E 清单

**Files:**
- Modify: `Sources/YierPet/PetController.swift`（buildMenu 状态列表）
- Modify: `README.md`

**Interfaces:**
- Consumes: `AgentCenter.snapshot`（Task 3）
- Produces: 完整功能 + 文档

- [ ] **Step 1: Agent 哨兵菜单展示当前会话**

`buildMenu()` 的 Agent 哨兵子菜单末尾（卸载项之后）追加：

```swift
        let sessions = agentCenter.snapshot
        if !sessions.isEmpty {
            agentMenu.addItem(.separator())
            for info in sessions {
                let stateText: String
                switch info.state {
                case .working: stateText = "干活中"
                case .needsConfirm: stateText = "等确认"
                case .done: stateText = "已完成"
                }
                let item = NSMenuItem(
                    title: "\(info.tool.rawValue) · \(info.project) — \(stateText)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                agentMenu.addItem(item)
            }
        }
```

- [ ] **Step 2: README 更新**

在 README 功能列表处新增"Agent 哨兵"小节（措辞对齐 README 现有风格），要点：

- 支持 qwen / qodercli / opencode / omp / dsh 五个 agent 工具的状态监听（等确认/报错/完成提醒 + 工作中状态展示）；
- 原理：各工具官方 hook/插件机制 → 仅本机回环（127.0.0.1）的最小 HTTP 监听，无网络权限请求、无子进程、无第三方依赖；
- 使用：右键菜单 → Agent 哨兵 → 安装 Agent 钩子；卸载同样一键；钩子在 YierPet 未运行时静默失败，不影响 agent。

同时修正 README 中"零依赖、零权限、不起子进程"的表述：保持零第三方依赖、零额外权限、不起子进程，但注明新增了仅本机回环的事件监听端口。

- [ ] **Step 3: 全量构建 + 测试**

Run: `swift test 2>&1 | tail -3 && ./build.sh`
Expected: 全 PASS，构建成功。

- [ ] **Step 4: 按 spec §9 跑完整 E2E 清单并记录结果**

逐项执行（全部要过）：

1. qwen 触发权限弹窗 → 宠物气泡+动作+声音；终端回应后轻提醒停止
2. qwen 完成一轮 → done 气泡
3. 退出 YierPet 后运行带钩子的 qwen → agent 不阻塞、无报错（钩子静默失败，≤1s）
4. 重启 YierPet（端口变化）→ 钩子自动恢复（endpoint 文件已更新）
5. 安装/卸载钩子各一遍 → 各配置文件只增删 yierpet 条目，yunke/loongsuite 等他人条目不受影响，备份文件存在
6. dsh 内置宠物已隐藏
7. 多会话：同时跑 qwen 与 opencode → 菜单状态列表各显示一条；同时等确认时气泡按 needsConfirm 优先级提醒
8. 静默清理：agent 直接 kill 后 10 分钟以上 → 状态列表中该会话消失（可临时把 staleAfter 调短验证，验证后改回 600）

- [ ] **Step 5: Commit**

```bash
git add Sources/YierPet/PetController.swift README.md
git commit -m "feat: Agent 哨兵——会话状态展示与 README 文档，功能完成"
```

---

## Self-Review 记录

- **Spec 覆盖**：§3 架构（Task 2/3）、§4 协议（Task 1/4 hook.sh header 方案）、§5 状态模型（Task 1 状态机 + 测试逐条对应）、§6 YierPet 改动（Task 1-3、7）、§7 安装/卸载（Task 4-6）、§8 错误处理（hook.sh 静默失败 Task 4；解析失败跳过 Task 4 installSettingsHooks throws→failed 列表；未知 tool/hook Task 1 default 分支 + Task 2 parse 返回 nil；端口占用 Task 2 绑端口 0）、§9 测试（Task 3 测试菜单 + Task 7 E2E 清单）、§10 顺序一致。dsh pet.visible 在 Task 6。README 在 Task 7。
- **占位符扫描**：仅 Task 6 Step 2 的 dsh 扩展路径依赖 Step 1 调研结论——这是 spec 明确标注的"实现时确认扩展点"，已给出判定标准与三种方案分支，非模糊占位。
- **类型一致性**：`AgentEvent/AgentAlert/AgentTool/AgentSessionStore`（Task 1）→ `AgentServer.onEvent/endpointString`（Task 2）→ `AgentCenter.handle/fire/simulate/snapshot` 与 `AgentCenterDelegate.agentCenter(_:fire:message:)`（Task 3）→ `AgentHookInstaller`（Task 4-6）签名逐一对齐；`ReminderKind.agentNeedsConfirm/agentDone/agentError` 在 Task 2 定义、Task 3 消费。