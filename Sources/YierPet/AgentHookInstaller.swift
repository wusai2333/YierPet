import Foundation
import CryptoKit

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

    /// Codex CLI 的 hooks.json 只认这份事件表（codex 0.166 实测）。
    /// Notification / StopFailure / PostToolUseFailure 都不存在，而未知
    /// 事件键会让整个 hooks.json 解析失败、连带别人的钩子一起失效，
    /// 所以这里一个都不多加。报错提醒因此退化到 Stop 摘要里带错误原文。
    static let codexHookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SessionEnd",
    ]

    static let codexSettingsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/hooks.json")
    static let codexConfigURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/config.toml")

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

    // MARK: - settings.json tools (qwen / qodercli / codex)

    static func installSettingsHooks(
        settingsPath: String, tool: AgentTool
    ) throws {
        try installSettingsHooks(
            settingsPath: settingsPath, tool: tool, events: hookEvents)
    }

    /// Shared merge-in: own entries are dropped then re-appended per event,
    /// so existing (foreign) entries keep their position and their trust.
    private static func installSettingsHooks(
        settingsPath: String, tool: AgentTool, events: [String]
    ) throws {
        let url = URL(fileURLWithPath: settingsPath)
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else { throw NSError(domain: "yierpet", code: 1) }
        backup(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for eventName in events {
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

    // MARK: - codex (Codex CLI: hooks.json + [hooks.state] trust)

    /// codex 只跑「已授信」的用户钩子：授信写在 config.toml 的
    /// `[hooks.state."<hooks.json 路径>:<snake 事件>:<组>:< handler>"]
    /// trusted_hash = "sha256:…"`，哈希是钩子身份的规范化 JSON 摘要。
    /// 我们复刻这个算法，只给自己写的条目授信，所以安装后不必再去
    /// `/hooks` 逐条确认，也绝不碰别人钩子的授信键。若哪天 codex 改了
    /// 配方，我们的条目会被静默跳过——一次 `/hooks` 手工确认即可恢复。
    static func installCodexHooks(
        settingsPath: String = codexSettingsURL.path,
        configPath: String = codexConfigURL.path
    ) throws {
        // Sweep every pre-existing own entry first, across all events:
        // trust is only computed for codexHookEvents, so an entry an older
        // build wrote under a since-dropped event would stay in the file
        // untrusted and silently never fire.
        try uninstallSettingsHooks(settingsPath: settingsPath)
        try installSettingsHooks(
            settingsPath: settingsPath, tool: .codex,
            events: codexHookEvents)
        writeHookStateTrust(
            configPath: configPath, trust: codexTrust(settingsPath: settingsPath))
    }

    static func uninstallCodexHooks(
        settingsPath: String = codexSettingsURL.path,
        configPath: String = codexConfigURL.path
    ) throws {
        // Read our trust keys BEFORE removing the entries: positional keys
        // and hashes stop existing once the entries are gone. Only these
        // exact key+hash pairs are deleted — a foreign hook that shares
        // hooks.json keeps its own `[hooks.state]` entry untouched.
        let trust = codexTrust(settingsPath: settingsPath)
        try uninstallSettingsHooks(settingsPath: settingsPath)
        removeHookStateTrust(configPath: configPath, trust: trust)
    }

    /// `[hooks.state]` key → trusted_hash for our own entries.
    static func codexTrust(settingsPath: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in codexTrustEntries(settingsPath: settingsPath) {
            out[codexHookStateKey(
                settingsPath: settingsPath, event: entry.event,
                group: entry.group, handler: entry.handler)] = entry.hash
        }
        return out
    }

    /// 我们自己那些条目对应的授信键值（组号 = 该事件下的位置）。
    static func codexTrustEntries(settingsPath: String) -> [
        (event: String, group: Int, handler: Int, hash: String)
    ] {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: settingsPath)),
            let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return [] }
        var out: [(String, Int, Int, String)] = []
        for event in codexHookEvents {
            let entries = hooks[event] as? [[String: Any]] ?? []
            for (group, entry) in entries.enumerated() where isOwnEntry(entry) {
                let matcher = entry["matcher"] as? String
                let handlers = entry["hooks"] as? [[String: Any]] ?? []
                for (handler, item) in handlers.enumerated() {
                    out.append((
                        event, group, handler,
                        codexTrustedHash(
                            event: event, matcher: matcher,
                            handler: item)))
                }
            }
        }
        return out
    }

    static func codexHookStateKey(
        settingsPath: String, event: String, group: Int, handler: Int = 0
    ) -> String {
        "\(settingsPath):\(codexSnakeCase(event)):\(group):\(handler)"
    }

    /// 钩子身份 → codex 的 trusted_hash。规范化规则（0.166 实测对齐）：
    /// 事件名转 snake_case；matcher 缺省或 "*" 不入库；handler 补齐
    /// type / timeout（缺省 600）/ async（缺省 false）；JSON 键排序紧凑。
    static func codexTrustedHash(
        event: String, matcher: String?, handler: [String: Any]
    ) -> String {
        var normalized: [String: Any] = [
            "type": handler["type"] as? String ?? "command",
            "command": handler["command"] as? String ?? "",
            "timeout": handler["timeout"] as? Int ?? 600,
            "async": handler["async"] as? Bool ?? false,
        ]
        if let statusMessage = handler["statusMessage"] as? String {
            normalized["statusMessage"] = statusMessage
        }
        var identity: [String: Any] = ["event_name": codexSnakeCase(event)]
        if let matcher, matcher != "*" { identity["matcher"] = matcher }
        identity["hooks"] = [normalized]
        let digest = SHA256.hash(
            data: Data(codexCompactJSON(identity).utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }
            .joined()
    }

    static func codexSnakeCase(_ value: String) -> String {
        var out = ""
        for char in value {
            if char.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(char.lowercased())
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// 手写紧凑 JSON（键排序）：JSONSerialization 没有紧凑模式，
    /// 事后 replace ": " 会误伤字符串内容。
    static func codexCompactJSON(_ value: Any) -> String {
        switch value {
        case let string as String:
            return codexJSONString(string)
        case let number as Int:
            return String(number)
        case let number as Double:
            return String(number)
        case let bool as Bool:
            return bool ? "true" : "false"
        case is NSNull:
            return "null"
        case let array as [Any]:
            return "[" + array.map(codexCompactJSON).joined(separator: ",") + "]"
        case let dict as [String: Any]:
            let parts = dict.keys.sorted().map {
                codexJSONString($0) + ":" + codexCompactJSON(dict[$0]!)
            }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            return "null"
        }
    }

    private static func codexJSONString(_ value: String) -> String {
        var out = "\""
        for char in value.unicodeScalars {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if char.value < 0x20 {
                    out += String(
                        format: "\\u%04x", char.value)
                } else {
                    out.unicodeScalars.append(char)
                }
            }
        }
        return out + "\""
    }

    // MARK: - [hooks.state] TOML editing (only ever touches our own keys)

    /// Rewrites our trust region: existing blocks for these exact keys are
    /// dropped first, then a fresh `# yierpet codex hook trust` block is
    /// appended, so repeated installs stay clean and one-off keys from an
    /// older layout don't linger.
    static func writeHookStateTrust(
        configPath: String, trust: [String: String]
    ) {
        let url = URL(fileURLWithPath: configPath)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
        let keys = Set(trust.keys)
        lines = pruneHookStateTables(lines) { key, _ in keys.contains(key) }.lines
        var block = [""]
        for key in keys.sorted() {
            block.append("[hooks.state.\"\(tomlEscape(key))\"]")
            block.append("trusted_hash = \"\(tomlEscape(trust[key]!))\"")
        }
        lines.append(contentsOf: block)
        try? lines.joined(separator: "\n")
            .data(using: .utf8)?.write(to: url)
    }

    /// Removes exactly the given key+hash tables (and nothing else), plus
    /// our marker comments. Returns the number of dropped tables.
    @discardableResult
    static func removeHookStateTrust(
        configPath: String, trust: [String: String]
    ) -> Int {
        let url = URL(fileURLWithPath: configPath)
        guard let text = try? String(
            contentsOf: url, encoding: .utf8)
        else { return 0 }
        let (kept, removed) = pruneHookStateTables(text.components(separatedBy: "\n")) {
            trust[$0] == $1
        }
        try? kept.joined(separator: "\n")
            .data(using: .utf8)?.write(to: url)
        return removed
    }

    /// Legacy region comments written by earlier builds. codex rewrites
    /// config.toml and reorders tables, which can strand such a comment far
    /// from its block — so we no longer write them (the state key already
    /// carries the hooks.json path) but still delete any we find.
    static let trustMarker = "# yierpet codex hook trust"

    /// Drops `[hooks.state]` tables whose (key, trusted_hash) satisfies
    /// `matches`, keeping every other line — including unrelated tables —
    /// byte-identical.
    private static func pruneHookStateTables(
        _ lines: [String], matching: (String, String) -> Bool
    ) -> (lines: [String], removed: Int) {
        var out: [String] = []
        var removed = 0
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Legacy marker comments vanish wherever codex left them.
            if trimmed.hasPrefix(trustMarker) {
                index += 1
                continue
            }
            guard trimmed.hasPrefix("[hooks.state."),
                  let key = hookStateKey(from: trimmed) else {
                out.append(line)
                index += 1
                continue
            }
            var body: [String] = []
            var hash: String?
            var cursor = index + 1
            while cursor < lines.count {
                let next = lines[cursor]
                    .trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("[") { break }
                if next.hasPrefix("trusted_hash") {
                    hash = unquotedValue(from: next)
                }
                body.append(lines[cursor])
                cursor += 1
            }
            if matching(key, hash ?? "") {
                removed += 1
            } else {
                out.append(line)
                out.append(contentsOf: body)
            }
            index = cursor
        }
        return (out, removed)
    }

    /// `"path:event:i:j"` out of `[hooks.state."<key>"]`, unescaped.
    private static func hookStateKey(from header: String) -> String? {
        guard let firstQuote = header.firstIndex(of: "\"") else { return nil }
        guard let lastQuote = header.lastIndex(of: "\""),
              lastQuote > firstQuote else { return nil }
        return unescapeTomlString(
            String(header[header.index(after: firstQuote)..<lastQuote]))
    }

    /// The quoted right-hand side of `trusted_hash = "sha256:…"`.
    private static func unquotedValue(from line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let rhs = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 else { return nil }
        return unescapeTomlString(String(rhs.dropFirst().dropLast()))
    }

    private static func unescapeTomlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        // codex 把 SessionEnd 钩子的超时钳到 3s（超了会在启动时告警）；
        // hook.sh 的 curl 本身就只等 1s，这里直接写它允许的上限。
        let timeout = (tool == .codex && event == "SessionEnd") ? 3 : 10
        return [
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": "\(scriptURL.path) \(tool.rawValue) \(event)",
                "timeout": timeout,
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

    /// codex keeps `[hooks.state]` trust in the config.toml next to the
    /// hooks file that declares the hooks.
    static func codexConfigPath(for hooksPath: String) -> String {
        (hooksPath as NSString).deletingLastPathComponent + "/config.toml"
    }

    /// Per-tool install dispatch: codex needs its own event table plus the
    /// config.toml trust region; the rest are plain Claude-style settings.json.
    static func installHooks(for tool: AgentTool, path: String) throws {
        switch tool {
        case .codex:
            try installCodexHooks(
                settingsPath: path, configPath: codexConfigPath(for: path))
        default:
            try installSettingsHooks(settingsPath: path, tool: tool)
        }
    }

    static func uninstallHooks(for tool: AgentTool, path: String) throws {
        switch tool {
        case .codex:
            try uninstallCodexHooks(
                settingsPath: path, configPath: codexConfigPath(for: path))
        default:
            try uninstallSettingsHooks(settingsPath: path)
        }
    }

    static func installAll() -> String {
        writeScript()
        let home = NSHomeDirectory()
        let targets: [(AgentTool, String)] = [
            (.qwen, "\(home)/.qwen/settings.json"),
            (.qodercli, "\(home)/.qoder/settings.json"),
            (.codex, codexSettingsURL.path),
        ]
        var ok: [String] = []
        var failed: [String] = []
        for (tool, path) in targets {
            do {
                try installHooks(for: tool, path: path)
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
        let targets: [(AgentTool, String)] = [
            (.qwen, "\(home)/.qwen/settings.json"),
            (.qodercli, "\(home)/.qoder/settings.json"),
            (.codex, codexSettingsURL.path),
        ]
        for (tool, path) in targets {
            try? uninstallHooks(for: tool, path: path)
        }
        uninstallOpencodePlugin()
        uninstallOmpExtension()
        uninstallOmoExtension()
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: AgentServer.endpointURL)
        return "Agent 钩子已卸载"
    }
}