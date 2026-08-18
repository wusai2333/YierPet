import Foundation
import Testing
@testable import YierPet

// 夹具单测：installSettingsHooks/uninstallSettingsHooks 接受任意路径，
// 全程只在临时目录操作，绝不碰用户真实的 ~/.qwen、~/.qoder 配置。

private let marker = ".yierpet/hook.sh"

/// 临时目录里造一份迷你 settings.json：Notification 事件下挂一个
/// 他人钩子（命令不含 marker），外加一个无关顶层键。
private func makeFixture() throws -> (dir: URL, settings: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let settings = dir.appendingPathComponent("settings.json")
    let fixture: [String: Any] = [
        "model": "qwen-max",
        "hooks": [
            "Notification": [
                ["matcher": "result", "hooks": [
                    ["type": "command", "command": "/some/other/hook stop"],
                ]],
            ],
        ],
    ]
    try JSONSerialization.data(withJSONObject: fixture).write(to: settings)
    return (dir, settings)
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

private func ownCount(_ root: [String: Any], event: String) -> Int {
    entries(root, event: event).filter(isOwn).count
}

@Test func installAddsOwnEntriesKeepingForeignOnes() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installSettingsHooks(
        settingsPath: fixture.settings.path, tool: .qwen)

    let root = try loadRoot(fixture.settings)
    // 无关顶层键未动
    #expect(root["model"] as? String == "qwen-max")
    for event in AgentHookInstaller.hookEvents {
        // 每个事件恰有一个自有条目，命令含 hook.sh + 工具 + 事件名
        #expect(ownCount(root, event: event) == 1)
        let own = entries(root, event: event).first(where: isOwn)
        let inner = own?["hooks"] as? [[String: Any]] ?? []
        #expect(inner.contains {
            ($0["command"] as? String)?
                .contains("\(marker) qwen \(event)") == true
        })
    }
    // 他人条目原样保留（Notification = 他人 1 + 自有 1）
    let notification = entries(root, event: "Notification")
    #expect(notification.count == 2)
    #expect(notification.contains { entry in
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains {
            ($0["command"] as? String) == "/some/other/hook stop"
        }
    })
    // 写前备份已生成
    #expect(FileManager.default.fileExists(
        atPath: fixture.settings.path + ".yierpet-bak"))
}

@Test func installIsIdempotent() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installSettingsHooks(
        settingsPath: fixture.settings.path, tool: .qwen)
    try AgentHookInstaller.installSettingsHooks(
        settingsPath: fixture.settings.path, tool: .qwen)

    let root = try loadRoot(fixture.settings)
    for event in AgentHookInstaller.hookEvents {
        #expect(ownCount(root, event: event) == 1)
    }
    // 他人条目仍只有一份
    #expect(entries(root, event: "Notification").count == 2)
}

@Test func uninstallRemovesOwnEntriesOnly() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.installSettingsHooks(
        settingsPath: fixture.settings.path, tool: .qwen)
    try AgentHookInstaller.uninstallSettingsHooks(
        settingsPath: fixture.settings.path)

    let root = try loadRoot(fixture.settings)
    #expect(root["model"] as? String == "qwen-max")
    for event in AgentHookInstaller.hookEvents {
        #expect(ownCount(root, event: event) == 0)
    }
    // 他人条目仍在；只剩它的 Notification 保留，纯自有事件被整个删掉
    let notification = entries(root, event: "Notification")
    #expect(notification.count == 1)
    #expect(!isOwn(notification[0]))
    let hooks = root["hooks"] as? [String: Any] ?? [:]
    #expect(hooks.keys.sorted() == ["Notification"])
}

@Test func writeScriptCreatesExecutableHookSh() throws {
    AgentHookInstaller.writeScript()
    let attrs = try FileManager.default.attributesOfItem(
        atPath: AgentHookInstaller.scriptURL.path)
    #expect(attrs[.posixPermissions] as? Int == 0o755)
    let content = try String(
        contentsOf: AgentHookInstaller.scriptURL, encoding: .utf8)
    #expect(content.hasPrefix("#!/bin/sh"))
    #expect(content.contains("curl -m 1"))
}

// MARK: - opencode plugin registration

// 夹具单测：registerOpencodePlugin/unregisterOpencodePlugin 接受任意
// configURL，全程只在临时目录操作，绝不碰用户真实的 opencode.json。

/// 临时目录里造一份迷你 opencode.json：两个既有 plugin 条目
/// （一个远端名、一个他人 file:// 本地插件）外加一个无关顶层键。
private func makeOpencodeFixture() throws -> (dir: URL, config: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yierpet-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let config = dir.appendingPathComponent("opencode.json")
    let fixture: [String: Any] = [
        "plugin": ["some-existing-plugin", "file:///tmp/other-local.ts"],
        "other": 1,
    ]
    try JSONSerialization.data(withJSONObject: fixture).write(to: config)
    return (dir, config)
}

private func pluginList(_ root: [String: Any]) -> [String] {
    root["plugin"] as? [String] ?? []
}

@Test func registerOpencodePluginAppendsEntryKeepingExisting() throws {
    let fixture = try makeOpencodeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.registerOpencodePlugin(
        configURL: fixture.config, pluginPath: "/tmp/fake/yierpet.ts")

    let root = try loadRoot(fixture.config)
    #expect(pluginList(root) == [
        "some-existing-plugin",
        "file:///tmp/other-local.ts",
        "file:///tmp/fake/yierpet.ts",
    ])
    // 无关顶层键未动
    #expect(root["other"] as? Int == 1)
    // 写前备份已生成
    #expect(FileManager.default.fileExists(
        atPath: fixture.config.path + ".yierpet-bak"))
}

@Test func registerOpencodePluginIsIdempotent() throws {
    let fixture = try makeOpencodeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.registerOpencodePlugin(
        configURL: fixture.config, pluginPath: "/tmp/fake/yierpet.ts")
    try AgentHookInstaller.registerOpencodePlugin(
        configURL: fixture.config, pluginPath: "/tmp/fake/yierpet.ts")

    let root = try loadRoot(fixture.config)
    let list = pluginList(root)
    #expect(list.filter { $0.contains("yierpet") }.count == 1)
    // 既有条目仍只有一份
    #expect(list.count == 3)
}

@Test func unregisterOpencodePluginRemovesOwnEntryOnly() throws {
    let fixture = try makeOpencodeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    try AgentHookInstaller.registerOpencodePlugin(
        configURL: fixture.config, pluginPath: "/tmp/fake/yierpet.ts")
    AgentHookInstaller.unregisterOpencodePlugin(configURL: fixture.config)

    let root = try loadRoot(fixture.config)
    #expect(pluginList(root) == [
        "some-existing-plugin", "file:///tmp/other-local.ts",
    ])
    #expect(root["other"] as? Int == 1)
}
