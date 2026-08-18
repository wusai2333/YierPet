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
