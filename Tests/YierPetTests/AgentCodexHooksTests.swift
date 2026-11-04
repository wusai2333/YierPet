import Foundation
import Testing
@testable import YierPet

// 夹具单测：codex 接入只碰临时目录里的假 hooks.json / config.toml，
// 绝不读写用户真实的 ~/.codex。

private let marker = ".yierpet/hook.sh"

/// 真实取证过的 codex 授信值（来自用户机器 config.toml 的现存条目），
/// 用来钉住我们复刻的 trusted_hash 算法。
private let r2cPreToolUseHash =
    "sha256:3e95746331f6b1d3d7a572c6a35560ea5b53feb9a26daea15732b23912dcb715"
private let loongsuiteStopHash =
    "sha256:bac26d0da5710572bcf04ceb19239694e466e10a37982de84fbd58465b13d5ca"
/// 一个"陈旧"授信（命令后来被改过）：codex 会显示 Modified 并跳过，
/// 我们既不该复用也不该删除它。
private let staleFailureHash =
    "sha256:6aa45510f52a03e84d8bf02a8a93435fda8abfc5d9bdcaa34f0c63dae7b8bf2e"

/// 迷你 codex hooks.json：别人的钩子（带 matcher、多 handler、通配组）
/// 加一个无关顶层键，用来验证合并只动 yierpet 自己的条目。
private func makeCodexFixture() throws -> (dir: URL, hooks: URL, config: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let hooks = dir.appendingPathComponent("hooks.json")
    let fixture: [String: Any] = [
        "description": "user hooks",
        "hooks": [
            "PostToolUse": [
                ["matcher": "Bash", "hooks": [[
                    "type": "command", "command": "/other/hook.sh",
                    "timeout": 10,
                ]]],
                ["hooks": [
                    ["type": "command", "command": "/a.sh"],
                    ["type": "command", "command": "/b.sh", "timeout": 5],
                ]],
            ],
            "PreToolUse": [
                ["matcher": "Bash", "hooks": [[
                    "type": "command",
                    "command": "bash \"/Users/wusai/.r2c/scripts/"
                        + "codex-http/pre/codex-shell-hook.sh\"",
                    "timeout": 5,
                ]]],
            ],
            "Stop": [
                ["matcher": "*", "hooks": [[
                    "type": "command",
                    "command": "/Users/wusai/.loongsuite-pilot/hooks/"
                        + "codex-loongsuite-pilot-hook.sh stop",
                ]]],
            ],
            "PostToolUseFailure": [
                ["matcher": "Bash", "hooks": [[
                    "type": "command", "command": "/failure/hook.sh",
                    "timeout": 5,
                ]]],
            ],
        ],
    ]
    try JSONSerialization.data(withJSONObject: fixture).write(to: hooks)
    let config = dir.appendingPathComponent("config.toml")
    let configText = """
    model = "gpt-6.1-sol"

    [hooks]

    [hooks.state]

    [hooks.state."<P>:pre_tool_use:0:0"]
    trusted_hash = "\(r2cPreToolUseHash)"

    [hooks.state."<P>:stop:0:0"]
    trusted_hash = "\(loongsuiteStopHash)"

    [hooks.state."<P>:post_tool_use_failure:0:0"]
    trusted_hash = "\(staleFailureHash)"

    [features]
    hooks = true

    [projects."~/x"]
    trust_level = "trusted"

    """
    try configText.replacingOccurrences(of: "<P>", with: hooks.path)
        .data(using: .utf8)!.write(to: config)
    return (dir, hooks, config)
}

private func loadRoot(_ url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}

private func entries(_ root: [String: Any], event: String) -> [[String: Any]] {
    let hooks = root["hooks"] as? [String: Any] ?? [:]
    return hooks[event] as? [[String: Any]] ?? []
}

private func isOwn(_ entry: [String: Any]) -> Bool {
    let inner = entry["hooks"] as? [[String: Any]] ?? []
    return inner.contains {
        ($0["command"] as? String)?.contains(marker) == true
    }
}

private func ownCommands(_ root: [String: Any], event: String) -> [String] {
    entries(root, event: event).filter(isOwn).flatMap { entry in
        (entry["hooks"] as? [[String: Any]] ?? []).compactMap {
            $0["command"] as? String
        }
    }
}

private func text(of url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

// MARK: - 事件表与合并

@Test func codexInstallAppendsOwnEntriesKeepingForeignOnes() throws {
    let fixture = try makeCodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)

    let root = try loadRoot(fixture.hooks)
    #expect(root["description"] as? String == "user hooks")
    for event in AgentHookInstaller.codexHookEvents {
        #expect(ownCommands(root, event: event) == [
            "\(AgentHookInstaller.scriptURL.path) codex \(event)",
        ])
        // 我们自己的组排在最后；matcher 写 "*"（等价通配），且规范化
        // 时不入摘要 —— 这正是授信哈希能对齐的前提
        #expect(entries(root, event: event).last.map(isOwn) == true)
        #expect(entries(root, event: event).last?["matcher"] as? String == "*")
    }
    // 别人的条目原样、原位 —— trust 键按位置算，位置不能漂
    #expect(entries(root, event: "PostToolUse").count == 3)
    #expect(entries(root, event: "PostToolUse")[0]["matcher"] as? String == "Bash")
    #expect(entries(root, event: "Stop").count == 2)
    #expect(!isOwn(entries(root, event: "Stop")[0]))
    // codex 不认的事件不许往里塞（未知键会让整个 hooks.json 解析失败）
    #expect(entries(root, event: "PostToolUseFailure").count == 1)
    #expect(ownCommands(root, event: "PostToolUseFailure").isEmpty)
    #expect(!AgentHookInstaller.codexHookEvents.contains("Notification"))
    #expect(!AgentHookInstaller.codexHookEvents.contains("StopFailure"))
    #expect(!AgentHookInstaller.codexHookEvents.contains("PostToolUseFailure"))
}

@Test func codexInstallIsIdempotent() throws {
    let fixture = try makeCodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)
    try AgentHookInstaller.installCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)

    let root = try loadRoot(fixture.hooks)
    for event in AgentHookInstaller.codexHookEvents {
        #expect(ownCommands(root, event: event).count == 1)
    }
    #expect(entries(root, event: "PostToolUse").count == 3)
    let config = try text(of: fixture.config)
    #expect(config.components(
        separatedBy: AgentHookInstaller.trustMarker).count == 1)
}

// codex 会重写 config.toml 并重排表，注释式区域标记会被甩到别处变成孤儿。
// 所以不再写标记，并且要把旧版本留下的散落标记清掉。
@Test func writeHookStateTrustClearsLegacyMarkerLines() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = dir.appendingPathComponent("config.toml")
    try """
    model = "gpt-6.1-sol"

    \(AgentHookInstaller.trustMarker) BEGIN

    [tui]
    screen_reader_detection = true

    [projects."~/x"]
    trust_level = "trusted"

    """.data(using: .utf8)!.write(to: config)

    AgentHookInstaller.writeHookStateTrust(configPath: config.path, trust: [
        "/tmp/h.json:stop:0:0": "sha256:aa",
    ])
    let written = try text(of: config)
    #expect(!written.contains(AgentHookInstaller.trustMarker))
    // 别人的段落原样保留
    #expect(written.contains("[tui]"))
    #expect(written.contains("screen_reader_detection = true"))
    #expect(written.contains("[projects.\"~/x\"]"))
    #expect(written.contains("model = \"gpt-6.1-sol\""))
    // 我们的块只有一个，且带值
    #expect(written.components(separatedBy: "[hooks.state.\"/tmp/h.json:stop:0:0\"]").count == 2)
    #expect(written.contains("trusted_hash = \"sha256:aa\""))
}

@Test func codexInstallNeverShiftsForeignTrustKeys() throws {
    let fixture = try makeCodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let before = try text(of: fixture.config)
    try AgentHookInstaller.installCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)
    let after = try text(of: fixture.config)
    for line in before.components(separatedBy: "\n") where
        line.hasPrefix("[hooks.state.") || line.hasPrefix("trusted_hash") {
        #expect(after.contains(line), "别人的授信被动过：\(line)")
    }
    #expect(after.contains("[features]"))
    #expect(after.contains("hooks = true"))
    #expect(after.contains("[projects.\"~/x\"]"))
    #expect(after.contains("trust_level = \"trusted\""))
    #expect(after.contains("model = \"gpt-6.1-sol\""))
}

@Test func codexUninstallRemovesOwnEntriesAndTrustOnly() throws {
    let fixture = try makeCodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)
    try AgentHookInstaller.uninstallCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)

    let root = try loadRoot(fixture.hooks)
    for event in AgentHookInstaller.codexHookEvents {
        #expect(ownCommands(root, event: event).isEmpty)
    }
    // 只有纯自有的事件被删空；别人的事件/条目都回来了
    #expect(entries(root, event: "PostToolUse").count == 2)
    #expect(entries(root, event: "Stop").count == 1)
    #expect(entries(root, event: "PreToolUse").count == 1)
    #expect(entries(root, event: "PostToolUseFailure").count == 1)

    let config = try text(of: fixture.config)
    #expect(!config.contains(AgentHookInstaller.trustMarker))
    // 我们那些键（位置 + 哈希）整段消失
    #expect(!config.contains("\(fixture.hooks.path):stop:1:0"))
    #expect(!config.contains("\(fixture.hooks.path):session_start:0:0"))
    // 别人的授信一字不动，连陈旧的那条也不碰
    #expect(config.contains("\(fixture.hooks.path):stop:0:0"))
    #expect(config.contains(r2cPreToolUseHash))
    #expect(config.contains(loongsuiteStopHash))
    #expect(config.contains(staleFailureHash))
    #expect(config.contains("[projects.\"~/x\"]"))
    #expect(config.contains("model = \"gpt-6.1-sol\""))
}

// MARK: - trusted_hash 复刻（对真实 codex 记录取证的向量）

@Test func codexTrustedHashMatchesCodexVectors() {
    // Stop 组带 matcher "*"：规范化时整个 matcher 字段不入摘要；
    // handler 没写 timeout/async → 补 600 / false
    #expect(AgentHookInstaller.codexTrustedHash(
        event: "Stop", matcher: "*",
        handler: [
            "type": "command",
            "command": "/Users/wusai/.loongsuite-pilot/hooks/"
                + "codex-loongsuite-pilot-hook.sh stop",
        ]) == loongsuiteStopHash)
    // 命令里带引号 + 显式 timeout，键排序后必须和 codex 一致
    #expect(AgentHookInstaller.codexTrustedHash(
        event: "PreToolUse", matcher: "Bash",
        handler: [
            "type": "command",
            "command": "bash \"/Users/wusai/.r2c/scripts/"
                + "codex-http/pre/codex-shell-hook.sh\"",
            "timeout": 5,
        ]) == r2cPreToolUseHash)
    // 陈旧授信不该被我们当成当前值：同一个条目算出来的哈希不同
    #expect(AgentHookInstaller.codexTrustedHash(
        event: "PostToolUseFailure", matcher: "Bash",
        handler: [
            "type": "command", "command": "bash \"/Users/wusai/.r2c/scripts/"
                + "codex-http/failure/codex-shell-hook.sh\"", "timeout": 5,
        ]) != staleFailureHash)
}

@Test func codexTrustEntriesKeysMatchWrittenBlock() throws {
    let fixture = try makeCodexFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installCodexHooks(
        settingsPath: fixture.hooks.path, configPath: fixture.config.path)
    let config = try text(of: fixture.config)
    let trustEntries = AgentHookInstaller.codexTrustEntries(
        settingsPath: fixture.hooks.path)
    #expect(trustEntries.count == AgentHookInstaller.codexHookEvents.count)
    for entry in trustEntries {
        let key = AgentHookInstaller.codexHookStateKey(
            settingsPath: fixture.hooks.path, event: entry.event,
            group: entry.group, handler: entry.handler)
        #expect(config.contains("[hooks.state.\"\(key)\"]"))
        #expect(config.contains("trusted_hash = \"\(entry.hash)\""))
    }
    // Stop 组 0 = 别人的 matcher "*" 条目，组 1 = 我们的；键跟着位置走
    #expect(trustEntries.first { $0.event == "Stop" }?.group == 1)
    #expect(trustEntries.first { $0.event == "SessionStart" }?.group == 0)
}

@Test func codexSnakeCaseMatchesCodexKeys() {
    #expect(AgentHookInstaller.codexSnakeCase("SessionStart") == "session_start")
    #expect(AgentHookInstaller.codexSnakeCase("UserPromptSubmit") == "user_prompt_submit")
    #expect(AgentHookInstaller.codexSnakeCase("PreToolUse") == "pre_tool_use")
    #expect(AgentHookInstaller.codexSnakeCase("PostToolUse") == "post_tool_use")
    #expect(AgentHookInstaller.codexSnakeCase("PermissionRequest") == "permission_request")
    #expect(AgentHookInstaller.codexSnakeCase("Stop") == "stop")
    #expect(AgentHookInstaller.codexSnakeCase("SessionEnd") == "session_end")
}

@Test func codexCompactJSONIsCanonical() {
    #expect(AgentHookInstaller.codexCompactJSON([
        "b": 1, "a": ["x", true], "c": NSNull(), "d": false,
    ] as [String: Any]) == "{\"a\":[\"x\",true],\"b\":1,\"c\":null,\"d\":false}")
    // 冒号/逗号出现在字符串里也不能被"压缩"掉
    #expect(AgentHookInstaller.codexCompactJSON([
        "k": "a: b, c",
    ] as [String: Any]) == "{\"k\":\"a: b, c\"}")
    #expect(AgentHookInstaller.codexCompactJSON([
        "k": "he said \"hi\"\n",
    ] as [String: Any]) == "{\"k\":\"he said \\\"hi\\\"\\n\"}")
}

@Test func codexConfigPathSitsNextToHooksFile() {
    #expect(AgentHookInstaller.codexConfigPath(
        for: "/tmp/x/hooks.json") == "/tmp/x/config.toml")
}

@Test func codexMissingHooksFileThrowsNotCrash() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    // 没装过 codex：hooks.json 不存在 → install 抛错，不崩、不凭空造文件
    #expect(throws: (any Error).self) {
        try AgentHookInstaller.installCodexHooks(
            settingsPath: dir.appendingPathComponent("hooks.json").path,
            configPath: dir.appendingPathComponent("config.toml").path)
    }
    // 卸载对不存在的文件是 no-op
    try AgentHookInstaller.uninstallCodexHooks(
        settingsPath: dir.appendingPathComponent("hooks.json").path,
        configPath: dir.appendingPathComponent("config.toml").path)
}

@Test func writeHookStateTrustOnMissingConfigCreatesIt() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = dir.appendingPathComponent("config.toml")
    AgentHookInstaller.writeHookStateTrust(configPath: config.path, trust: [
        "/tmp/h.json:stop:0:0": "sha256:aa",
    ])
    let written = try text(of: config)
    #expect(written.contains("[hooks.state.\"/tmp/h.json:stop:0:0\"]"))
    #expect(written.contains("trusted_hash = \"sha256:aa\""))
    // 再装一次：同键换哈希 → 覆盖而不是叠加
    AgentHookInstaller.writeHookStateTrust(configPath: config.path, trust: [
        "/tmp/h.json:stop:0:0": "sha256:bb",
    ])
    let again = try text(of: config)
    #expect(again.contains("sha256:bb"))
    #expect(!again.contains("sha256:aa"))
}
