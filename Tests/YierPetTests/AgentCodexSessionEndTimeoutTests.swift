import Foundation
import Testing
@testable import YierPet

// codex 对 SessionEnd 钩子有 3s 超时上限：写高了它启动时告警并自行钳制，
// 而超时值参与授信摘要，所以两边的值必须一致。
@Test func codexSessionEndUsesClampedTimeout() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let hooksURL = dir.appendingPathComponent("hooks.json")
    try Data(#"{"hooks":{},"x":1}"#.utf8).write(to: hooksURL)
    let configURL = dir.appendingPathComponent("config.toml")
    try Data("model = \"m\"\n".utf8).write(to: configURL)
    try AgentHookInstaller.installCodexHooks(
        settingsPath: hooksURL.path, configPath: configURL.path)

    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: hooksURL))
    let root = (object as? [String: Any]) ?? [:]
    let hooks = (root["hooks"] as? [String: Any]) ?? [:]
    func timeout(_ event: String) -> Int? {
        let groups = (hooks[event] as? [[String: Any]]) ?? []
        let last = groups.last ?? [:]
        let handlers = (last["hooks"] as? [[String: Any]]) ?? []
        return handlers.first?["timeout"] as? Int
    }
    #expect(timeout("SessionEnd") == 3)
    #expect(timeout("Stop") == 10)

    let trust = AgentHookInstaller.codexTrust(settingsPath: hooksURL.path)
    let key = AgentHookInstaller.codexHookStateKey(
        settingsPath: hooksURL.path, event: "SessionEnd", group: 0)
    let command = "\(AgentHookInstaller.scriptURL.path) codex SessionEnd"
    #expect(AgentHookInstaller.codexTrustedHash(
        event: "SessionEnd", matcher: "*",
        handler: ["type": "command", "command": command, "timeout": 3]
    ) == trust[key])
    #expect(AgentHookInstaller.codexTrustedHash(
        event: "SessionEnd", matcher: "*",
        handler: ["type": "command", "command": command, "timeout": 10]
    ) != trust[key])
}

// app 升级改了事件表时，旧版本写在已废弃事件下的条目必须被清掉：
// 授信只按当前 codexHookEvents 计算，孤儿条目会留在文件里且永不触发。
@Test func codexInstallSweepsOrphanEntriesOutsideEventTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let hooksURL = dir.appendingPathComponent("hooks.json")
    let configURL = dir.appendingPathComponent("config.toml")
    let script = AgentHookInstaller.scriptURL.path
    let legacy: [String: Any] = [
        "hooks": [
            // 旧版本写过、现已不在事件表里的事件 —— 两条都是 yierpet 自有
            "Notification": [["matcher": "*", "hooks": [[
                "type": "command", "command": "\(script) codex Notification",
                "timeout": 10,
            ]]]],
            "StopFailure": [["matcher": "*", "hooks": [[
                "type": "command", "command": "\(script) codex StopFailure",
                "timeout": 10,
            ]]]],
            // 别人的同名事件条目必须原样留着
            "SessionEnd": [["matcher": "x", "hooks": [[
                "type": "command", "command": "/other/hook.sh", "timeout": 5,
            ]]]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: legacy)
        .write(to: hooksURL)
    try Data("model = \"m\"\n".utf8).write(to: configURL)

    try AgentHookInstaller.installCodexHooks(
        settingsPath: hooksURL.path, configPath: configURL.path)

    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: hooksURL))
    let hooks = ((object as? [String: Any])?["hooks"] as? [String: Any]) ?? [:]
    func own(_ event: String) -> Int {
        let groups = (hooks[event] as? [[String: Any]]) ?? []
        return groups.filter { group in
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            return handlers.contains {
                (($0["command"] as? String) ?? "").contains(".yierpet/hook.sh")
            }
        }.count
    }
    #expect(own("Notification") == 0)
    #expect(own("StopFailure") == 0)
    // 当前事件表里每个事件恰有一条，且都拿到授信
    #expect(AgentHookInstaller.codexTrust(settingsPath: hooksURL.path).count
            == AgentHookInstaller.codexHookEvents.count)
    for event in AgentHookInstaller.codexHookEvents {
        #expect(own(event) == 1)
    }
    // 别人的条目不受扫描影响
    let sessionEnd = (hooks["SessionEnd"] as? [[String: Any]]) ?? []
    #expect(sessionEnd.count == 2)
    let first = ((sessionEnd.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
    #expect(first == "/other/hook.sh")
}
