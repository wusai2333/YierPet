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
