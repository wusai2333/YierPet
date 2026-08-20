import Foundation

/// Installs/uninstalls agent hooks. Idempotent: own entries are recognized
/// by the ".yierpet/hook.sh" marker; everything else is left untouched.
enum AgentHookInstaller {
    static let marker = ".yierpet/hook.sh"
    static let scriptURL = AgentServer.dir.appendingPathComponent("hook.sh")

    /// Claude-Code-style hook events registered for settings.json tools.
    /// StopFailure = the turn ended on an API error (rate limit / server),
    /// fires instead of Stop — that is the model-error reminder for these two.
    static let hookEvents = [
        "PermissionRequest", "Notification", "Stop", "StopFailure",
        "UserPromptSubmit", "PostToolUseFailure", "SessionEnd",
    ]

    static let opencodePluginURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/opencode/plugins/yierpet.ts")
    static let ompExtensionURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".omp/agent/extensions/yierpet-status.ts")
    static let omoExtensionURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".omo/agent/extensions/yierpet-status.ts")

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

    let lastAssistantText = "";

    function post(hook: string, cwd: string, extra: Record<string, unknown> = {}): void {
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
        body: JSON.stringify(extra),
        signal: AbortSignal.timeout(1000),
      }).catch(() => {});
    }

    function trackAssistantText(event: { type: string; properties?: any }): void {
      const props = event?.properties ?? {};
      const message = props.message ?? props.info;
      if (message && message.role && message.role !== "assistant") return;
      const parts: any[] = Array.isArray(props.parts)
        ? props.parts
        : props.part ? [props.part] : [];
      const text = parts
        .filter((p) => p?.type === "text" && typeof p.text === "string")
        .map((p) => p.text)
        .join(" ")
        .trim();
      if (text) lastAssistantText = text;
    }

    export const YierPetPlugin = async (ctx: { directory?: string }) => {
      const directory = ctx?.directory || process.cwd();
      return {
        event: async ({ event }: { event: any }) => {
          switch (event?.type) {
            case "session.idle":
              post("Stop", directory, { text: lastAssistantText });
              lastAssistantText = "";
              break;
            case "session.error": {
              const err = event?.properties?.error;
              const text = typeof err === "string"
                ? err : (err?.message ?? "");
              post("PostToolUseFailure", directory, { error: text });
              break;
            }
            case "session.status": {
              // Rate-limit / transient-error retry wait ("retrying in ...").
              const status = event?.properties?.status;
              if (status?.type === "retry" && status?.message) {
                post("PostToolUseFailure", directory, {
                  error: String(status.message),
                });
              }
              break;
            }
            case "message.updated":
            case "message.part.updated":
              trackAssistantText(event);
              post("PostToolUse", directory);
              break;
          }
        },
        "permission.ask": async (input: any) => {
          const desc = `${input?.type ?? "permission"}${
            input?.pattern ? ": " + input.pattern : ""}`;
          post("PermissionRequest", directory, { permission: desc });
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

    let lastAssistantText = ''

    function post(hookEventName: string, extra: Record<string, unknown> = {}): void {
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
        body: JSON.stringify(extra),
        ...(controller ? { signal: controller.signal } : {}),
      }).catch(() => {}).finally(() => clearTimeout(timeout))
    }

    function extractAssistantText(message): string {
      const content = message?.content
      if (typeof content === 'string') return content
      if (!Array.isArray(content)) return ''
      return content
        .filter((b) => b?.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text)
        .join(' ')
        .trim()
    }

    export default function (pi): void {
      pi.on('agent_start', () => {
        lastAssistantText = ''
        post('UserPromptSubmit')
      })
      pi.on('tool_execution_start', () => post('PostToolUse'))
      pi.on('tool_execution_end', () => post('PostToolUse'))
      pi.on('message_end', (event) => {
        if (event?.message?.role !== 'assistant') return
        const text = extractAssistantText(event.message)
        if (text) lastAssistantText = text
        post('PostToolUse')
      })
      // Model rate-limit / transient error: an auto retry is starting.
      // YierPet's 60s error throttle absorbs retry bursts.
      pi.on('auto_retry_start', (event) => {
        const delayS = Math.max(1, Math.round((event?.delayMs ?? 0) / 1000))
        post('PostToolUseFailure', {
          error: `模型报错：${event?.errorMessage ?? '未知'}，${delayS}s 后重试 (${event?.attempt ?? '?'}/${event?.maxAttempts ?? '?'})`,
        })
      })
      pi.on('agent_settled', () => post('Stop', { text: lastAssistantText }))
      pi.on('agent_end', (event) => {
        // willContinue: an auto retry is scheduled — not a real settle yet.
        if (event?.willContinue) return
        post('Stop', { text: lastAssistantText })
      })
    }
    """#

    private static let omoExtensionSource = #"""
    // YierPet agent sentinel — forwards omo/senpi status to YierPet.
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

    let lastAssistantText = ''

    function post(hookEventName: string, extra: Record<string, unknown> = {}): void {
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
          'X-YierPet-Tool': 'omo',
          'X-YierPet-Hook': hookEventName,
          'X-YierPet-Cwd': process.cwd(),
        },
        body: JSON.stringify(extra),
        ...(controller ? { signal: controller.signal } : {}),
      }).catch(() => {}).finally(() => clearTimeout(timeout))
    }

    function extractAssistantText(message): string {
      const content = message?.content
      if (typeof content === 'string') return content
      if (!Array.isArray(content)) return ''
      return content
        .filter((b) => b?.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text)
        .join(' ')
        .trim()
    }

    export default function (pi): void {
      pi.on('agent_start', () => {
        lastAssistantText = ''
        post('UserPromptSubmit')
      })
      pi.on('tool_execution_start', () => post('PostToolUse'))
      pi.on('tool_execution_end', () => post('PostToolUse'))
      pi.on('message_end', (event) => {
        if (event?.message?.role !== 'assistant') return
        const text = extractAssistantText(event.message)
        if (text) lastAssistantText = text
        post('PostToolUse')
      })
      // Model rate-limit / transient error: an auto retry is starting.
      // YierPet's 60s error throttle absorbs retry bursts.
      pi.on('auto_retry_start', (event) => {
        const delayS = Math.max(1, Math.round((event?.delayMs ?? 0) / 1000))
        post('PostToolUseFailure', {
          error: `模型报错：${event?.errorMessage ?? '未知'}，${delayS}s 后重试 (${event?.attempt ?? '?'}/${event?.maxAttempts ?? '?'})`,
        })
      })
      pi.on('agent_settled', () => post('Stop', { text: lastAssistantText }))
      pi.on('agent_end', (event) => {
        // willContinue: an auto retry is scheduled — not a real settle yet.
        if (event?.willContinue) return
        post('Stop', { text: lastAssistantText })
      })
    }
    """#

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

    // MARK: - opencode plugin / omp extension

    /// Testable layer behind installOpencodePlugin(): reads the
    /// opencode.json at configURL, backs it up, replaces any yierpet
    /// plugin entry with a file:// entry for pluginPath, writes back.
    static func registerOpencodePlugin(
        configURL: URL, pluginPath: String
    ) throws {
        guard let data = try? Data(contentsOf: configURL),
              var root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else { throw NSError(domain: "yierpet", code: 2) }
        backup(configURL)
        var plugins = root["plugin"] as? [String] ?? []
        plugins.removeAll { $0.contains("yierpet") }
        plugins.append("file://\(pluginPath)")
        root["plugin"] = plugins
        try write(root, to: configURL)
    }

    static func installOpencodePlugin() throws {
        let pluginDir = opencodePluginURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: pluginDir, withIntermediateDirectories: true)
        try opencodePluginSource.data(using: .utf8)?
            .write(to: opencodePluginURL)
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/opencode.json")
        try registerOpencodePlugin(
            configURL: configURL, pluginPath: opencodePluginURL.path)
    }

    static func unregisterOpencodePlugin(configURL: URL) {
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

    static func uninstallOpencodePlugin() {
        try? FileManager.default.removeItem(at: opencodePluginURL)
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/opencode.json")
        unregisterOpencodePlugin(configURL: configURL)
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

    static func installOmoExtension() throws {
        let extensionDir = omoExtensionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: extensionDir, withIntermediateDirectories: true)
        try omoExtensionSource.data(using: .utf8)?
            .write(to: omoExtensionURL)
    }

    static func uninstallOmoExtension() {
        try? FileManager.default.removeItem(at: omoExtensionURL)
    }

    // MARK: - dsh built-in pet

    static let dshSettingsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".dsh/settings.yaml")

    /// Testable layer behind disableDshBuiltinPet(): flips
    /// "pet:\n  visible: true" to false in the settings file at
    /// settingsPath, backing it up first. No-ops when the file is
    /// missing, has no visible pet section, or is already hidden.
    static func patchDshPetVisible(settingsPath: String) {
        let url = URL(fileURLWithPath: settingsPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let patched = text.replacingOccurrences(
            of: "pet:\n  visible: true",
            with: "pet:\n  visible: false")
        guard patched != text else { return }
        backup(url)
        try? patched.data(using: .utf8)?.write(to: url)
    }

    /// YierPet 取代 dsh 内置宠物（鲸鱼娘）：pet.visible → false。
    /// dsh 无自动发现的扩展目录（扩展是 Cordis 插件，按 profile 组合），
    /// 事件接入留空；卸载时也不恢复 pet.visible，避免鲸鱼娘突然复活。
    static func disableDshBuiltinPet() {
        patchDshPetVisible(settingsPath: dshSettingsURL.path)
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
        do {
            try installOmoExtension()
            ok.append("omo")
        } catch {
            failed.append("omo")
        }
        disableDshBuiltinPet()
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
        uninstallOpencodePlugin()
        uninstallOmpExtension()
        uninstallOmoExtension()
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: AgentServer.endpointURL)
        return "Agent 钩子已卸载"
    }
}
